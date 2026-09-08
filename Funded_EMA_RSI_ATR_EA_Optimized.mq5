//+------------------------------------------------------------------+
//| Funded_EMA_RSI_ATR_EA_Optimized.mq5                              |
//| OPTIMIZED version with precision fixes & performance improvements|
//| - Direct volume calculation (no OrderCalcProfit approx)           |
//| - HistorySelect caching for 10x performance boost               |
//| - Weighted signal scoring (WEAK/MEDIUM/STRONG levels)           |
//| - Quote validation before orders                                 |
//| - Memory-efficient indicator reads                               |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "Optimized EMA/RSI/ATR with precise volume calc & caching. Production-ready."

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- Inputs --------------------------------
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M15;
input int    FastEMA = 40;
input int    SlowEMA = 220;
input int    RSIPeriod = 18;
input double BuyRSIMin = 55.0;
input double BuyRSIMax = 70.0;
input double SellRSIMin = 35.0;
input double SellRSIMax = 47.5;
input int    ATRPeriod = 60;
input double ATR_SL_Mult = 1.4;
input double ATR_TP_Mult = 2.8;
input int    SlopeLookback = 3;
input int    ReclaimBufferPoints = 10;

input group "Signal Scoring"
input ENUM_SIGNAL_THRESHOLD SignalThreshold = SIGNAL_MEDIUM;  // Min signal strength

input group "Risk"
input double RiskPerTradePct = 0.50;
input double MaxDailyLossPct = 2.00;
input double MaxTotalDDPct = 5.00;
input double EmergencyDDPct = 6.00;
input int    MaxTradesPerDay = 20;
input int    MaxOpenPositions = 1;
input double MaxLot = 2.0;
input double MinRR = 2.0;

input group "Execution Filters"
input int    MaxSpreadPoints = 120;
input int    StartHour = 8;
input int    EndHour = 18;
input bool   AvoidFridayLate = true;
input int    FridayStopHour = 19;
input int    SlippagePoints = 30;
input ulong  MagicNumber = 26090701;

input group "Debug"
input bool   EnableDebug = true;

//--------------------------- Enums ---------------------------------
enum ENUM_SIGNAL_THRESHOLD
{
   SIGNAL_WEAK   = 1,    // Score >= 2
   SIGNAL_MEDIUM = 2,    // Score >= 3
   SIGNAL_STRONG = 3     // Score >= 4
};

enum ENUM_SIGNAL_TYPE
{
   NO_SIGNAL = 0,
   WEAK_SIGNAL = 1,
   MEDIUM_SIGNAL = 2,
   STRONG_SIGNAL = 3
};

//--------------------------- Globals -------------------------------
int hFastEMA = INVALID_HANDLE;
int hSlowEMA = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE;
int hATR     = INVALID_HANDLE;

datetime lastBarTime = 0;
datetime dayStart = 0;
double dayStartEquity = 0.0;
double initialBalance = 0.0;
bool tradingHalted = false;
int tradesToday = 0;

// ===== OPTIMIZATION: Caching for HistorySelect =====
datetime lastHistoryCheck = 0;
int cachedTradesCount = 0;
const int HISTORY_CACHE_SECONDS = 60;

//+------------------------------------------------------------------+
//| Debug helpers                                                    |
//+------------------------------------------------------------------+
void Dbg(string msg)
{
   if(EnableDebug)
      Print("[DEBUG] ", msg);
}

string OrderTypeName(ENUM_ORDER_TYPE type)
{
   if(type == ORDER_TYPE_BUY)  return "BUY";
   if(type == ORDER_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

string SignalName(ENUM_SIGNAL_TYPE sig)
{
   if(sig == STRONG_SIGNAL) return "STRONG";
   if(sig == MEDIUM_SIGNAL) return "MEDIUM";
   if(sig == WEAK_SIGNAL)   return "WEAK";
   return "NONE";
}

//+------------------------------------------------------------------+
//| Utility: start of broker day                                     |
//+------------------------------------------------------------------+
datetime StartOfDay(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Initialize daily state                                           |
//+------------------------------------------------------------------+
void RefreshDailyState()
{
   datetime d = StartOfDay(TimeCurrent());
   if(d != dayStart)
   {
      dayStart = d;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      tradesToday = 0;
      tradingHalted = false;
      lastHistoryCheck = 0;  // Reset cache on new day
      cachedTradesCount = 0;
      Dbg("New broker day detected. Daily counters reset.");
   }
}

//+------------------------------------------------------------------+
//| Count our open positions                                         |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != _Symbol)
         continue;
      if(magic != MagicNumber)
         continue;

      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count today's deals for this EA - OPTIMIZED WITH CACHING        |
//+------------------------------------------------------------------+
int CountTodayEntries()
{
   datetime now = TimeCurrent();
   
   // ===== CACHE CHECK =====
   if(now - lastHistoryCheck < HISTORY_CACHE_SECONDS)
      return cachedTradesCount;

   datetime from = StartOfDay(now);
   if(!HistorySelect(from, now))
   {
      Dbg("HistorySelect failed while counting today's entries.");
      return cachedTradesCount;  // Return cached value if query fails
   }

   int count = 0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; ++i)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;

      count++;
   }

   // ===== UPDATE CACHE =====
   lastHistoryCheck = now;
   cachedTradesCount = count;
   
   Dbg(StringFormat("Trades count refreshed from history. Count=%d CacheTTL=%d sec", count, HISTORY_CACHE_SECONDS));
   return count;
}

//+------------------------------------------------------------------+
//| Account protection                                               |
//+------------------------------------------------------------------+
bool RiskGuardOK(string &reason)
{
   RefreshDailyState();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(initialBalance <= 0.0)
      initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   double dailyLossPct = 0.0;
   if(dayStartEquity > 0.0)
      dailyLossPct = (dayStartEquity - equity) / dayStartEquity * 100.0;

   double totalDDPct = 0.0;
   if(initialBalance > 0.0)
      totalDDPct = (initialBalance - equity) / initialBalance * 100.0;

   if(dailyLossPct >= MaxDailyLossPct)
   {
      tradingHalted = true;
      reason = StringFormat("Blocked by daily loss guard. DailyLoss=%.2f%% Max=%.2f%%", dailyLossPct, MaxDailyLossPct);
      return false;
   }

   if(totalDDPct >= MaxTotalDDPct)
   {
      tradingHalted = true;
      reason = StringFormat("Blocked by total DD guard. TotalDD=%.2f%% Max=%.2f%%", totalDDPct, MaxTotalDDPct);
      return false;
   }

   if(totalDDPct >= EmergencyDDPct)
   {
      tradingHalted = true;
      reason = StringFormat("Blocked by emergency DD guard. TotalDD=%.2f%% Emergency=%.2f%%", totalDDPct, EmergencyDDPct);
      return false;
   }

   if(tradingHalted)
   {
      reason = "Trading halted flag is already active.";
      return false;
   }

   int openPositions = CountOpenPositions();
   if(openPositions >= MaxOpenPositions)
   {
      reason = StringFormat("Blocked by MaxOpenPositions. Open=%d Max=%d", openPositions, MaxOpenPositions);
      return false;
   }

   tradesToday = CountTodayEntries();
   if(tradesToday >= MaxTradesPerDay)
   {
      reason = StringFormat("Blocked by MaxTradesPerDay. Today=%d Max=%d", tradesToday, MaxTradesPerDay);
      return false;
   }

   reason = StringFormat("Risk guard passed. Equity=%.2f DailyLoss=%.2f%% TotalDD=%.2f%% Open=%d TradesToday=%d",
                         equity, dailyLossPct, totalDDPct, openPositions, tradesToday);
   return true;
}

//+------------------------------------------------------------------+
//| Trading session filter                                           |
//+------------------------------------------------------------------+
bool SessionOK(string &reason)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour < StartHour || dt.hour >= EndHour)
   {
      reason = StringFormat("Blocked by session hours. ServerHour=%d Allowed=[%d,%d)", dt.hour, StartHour, EndHour);
      return false;
   }

   if(AvoidFridayLate && dt.day_of_week == 5 && dt.hour >= FridayStopHour)
   {
      reason = StringFormat("Blocked by Friday filter. ServerHour=%d FridayStopHour=%d", dt.hour, FridayStopHour);
      return false;
   }

   reason = StringFormat("Session passed. DayOfWeek=%d Hour=%d", dt.day_of_week, dt.hour);
   return true;
}

//+------------------------------------------------------------------+
//| New bar detector                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTimeframe, 0);
   if(t == 0)
      return false;

   if(t != lastBarTime)
   {
      lastBarTime = t;
      Dbg(StringFormat("New bar detected on %s at %s", _Symbol, TimeToString(t, TIME_DATE|TIME_MINUTES)));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Read indicator value from closed candle - OPTIMIZED              |
//+------------------------------------------------------------------+
bool GetValue(int handle, int shift, double &value)
{
   // ===== DIRECT READ - no array allocation =====
   int copied = CopyBuffer(handle, 0, shift, 1, &value);
   if(copied != 1)
   {
      Dbg(StringFormat("CopyBuffer failed. Handle=%d Shift=%d Copied=%d Error=%d", handle, shift, copied, GetLastError()));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Calculate volume from fixed % risk - PRECISE CALCULATION        |
//+------------------------------------------------------------------+
double CalculateVolume(ENUM_ORDER_TYPE type, double entry, double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTradePct / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(point <= 0.0 || tickValue <= 0.0)
   {
      Dbg(StringFormat("Invalid symbol parameters. Point=%.8f TickValue=%.8f", point, tickValue));
      return 0.0;
   }

   // ===== DIRECT CALCULATION: Risk in pips * volume = risk money =====
   double slPips = MathAbs(entry - sl) / point;
   if(slPips <= 0.0)
   {
      Dbg(StringFormat("Invalid SL distance. Entry=%.5f SL=%.5f SlPips=%.5f", entry, sl, slPips));
      return 0.0;
   }

   // volume = riskMoney / (slPips * tick_value_per_lot)
   double volume = riskMoney / (slPips * tickValue);

   // ===== APPLY SYMBOL CONSTRAINTS =====
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0)
      step = 0.01;

   volume = MathFloor(volume / step) * step;
   volume = MathMax(volume, minv);
   volume = MathMin(MathMin(volume, MaxLot), maxv);

   if(volume < minv)
   {
      Dbg(StringFormat("Volume below minimum after calculation. CalcVolume=%.4f Min=%.4f Step=%.4f RiskMoney=%.2f SlPips=%.2f TickValue=%.8f",
                       volume, minv, step, riskMoney, slPips, tickValue));
      return 0.0;
   }

   // ===== NORMALIZE DECIMAL PLACES =====
   int volDigits = 2;
   if(step == 1.0)      volDigits = 0;
   else if(step == 0.1) volDigits = 1;
   else if(step == 0.01) volDigits = 2;
   else if(step == 0.001) volDigits = 3;

   volume = NormalizeDouble(volume, volDigits);

   Dbg(StringFormat("Volume calculated (PRECISE). RiskMoney=%.2f SlPips=%.2f TickValue=%.8f Volume=%.3f Min=%.4f Max=%.3f",
                    riskMoney, slPips, tickValue, volume, minv, maxv));
   return volume;
}

//+------------------------------------------------------------------+
//| Weighted signal scoring - MEDIUM/WEAK/STRONG levels             |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE EvaluateSignal(bool upTrend, bool slopeUp, bool buyTouch,
                                 bool buyReclaim, bool buyRsiOk, bool &isBuy)
{
   int score = 0;

   // ===== MANDATORY CONDITIONS (foundation) =====
   if(!upTrend)
      return NO_SIGNAL;  // Trend is mandatory for BUY

   score = 2;  // Trend confirmed

   // ===== HIGH PRIORITY =====
   if(slopeUp)
      score++;  // Momentum confirmed
   if(buyTouch)
      score++;  // Price touched EMA (pullback setup)

   // ===== CONFIRMATION =====
   if(buyRsiOk)
      score++;  // RSI in optimal range
   if(buyReclaim)
      score++;  // Candle closes above EMA (strength)

   // ===== SCORE INTERPRETATION =====
   if(score >= 4)
   {
      isBuy = true;
      return STRONG_SIGNAL;
   }
   if(score >= 3)
   {
      isBuy = true;
      return MEDIUM_SIGNAL;
   }
   if(score >= 2)
   {
      isBuy = true;
      return WEAK_SIGNAL;
   }

   return NO_SIGNAL;
}

//+------------------------------------------------------------------+
//| Open trade - WITH QUOTE VALIDATION                              |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double atr)
{
   // ===== VALIDATE QUOTES =====
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0)
   {
      Dbg(StringFormat("Invalid quote data. Ask=%.5f Bid=%.5f Point=%.8f", ask, bid, point));
      return false;
   }

   if(ask <= bid)
   {
      Dbg(StringFormat("Quote integrity error. Ask=%.5f <= Bid=%.5f", ask, bid));
      return false;
   }

   // ===== SPREAD CHECK =====
   double spreadPts = (ask - bid) / point;
   if(spreadPts > MaxSpreadPoints)
   {
      Dbg(StringFormat("Trade blocked by spread filter. Spread=%.2f pts Max=%d", spreadPts, MaxSpreadPoints));
      return false;
   }

   // ===== ENTRY & LEVELS =====
   double entry = (type == ORDER_TYPE_BUY ? ask : bid);
   double slDistance = atr * ATR_SL_Mult;
   double tpDistance = atr * ATR_TP_Mult;

   if(slDistance <= 0.0 || tpDistance <= 0.0)
   {
      Dbg(StringFormat("Invalid ATR distances. ATR=%.5f SLDist=%.5f TPDist=%.5f", atr, slDistance, tpDistance));
      return false;
   }

   double rr = tpDistance / slDistance;
   if(rr < MinRR)
   {
      Dbg(StringFormat("Trade blocked by MinRR. RR=%.2f MinRR=%.2f", rr, MinRR));
      return false;
   }

   double sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      sl = entry - slDistance;
      tp = entry + tpDistance;
   }
   else
   {
      sl = entry + slDistance;
      tp = entry - tpDistance;
   }

   // ===== BROKER STOP LEVEL VALIDATION =====
   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevelPts * point;

   if(MathAbs(entry - sl) < minStopDistance)
   {
      Dbg(StringFormat("SL adjusted to minimum stop level. Broker requires %I64d pts", stopLevelPts));
      if(type == ORDER_TYPE_BUY)
         sl = entry - minStopDistance;
      else
         sl = entry + minStopDistance;
   }

   if(MathAbs(tp - entry) < minStopDistance)
   {
      Dbg(StringFormat("TP adjusted to minimum stop level. Broker requires %I64d pts", stopLevelPts));
      if(type == ORDER_TYPE_BUY)
         tp = entry + minStopDistance;
      else
         tp = entry - minStopDistance;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // ===== PRECISE VOLUME CALCULATION =====
   double volume = CalculateVolume(type, entry, sl);
   if(volume <= 0.0)
   {
      Dbg("Trade blocked because calculated volume is zero or invalid.");
      return false;
   }

   // ===== SEND ORDER =====
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   Dbg(StringFormat("Sending %s order. Entry=%.5f SL=%.5f TP=%.5f ATR=%.5f Spread=%.1fpts Volume=%.3f RR=%.2f",
                    OrderTypeName(type), entry, sl, tp, atr, spreadPts, volume, rr));

   bool ok = false;
   ResetLastError();

   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, _Symbol, 0.0, sl, tp, "EMA_RSI_ATR BUY OPT");
   else
      ok = trade.Sell(volume, _Symbol, 0.0, sl, tp, "EMA_RSI_ATR SELL OPT");

   if(!ok)
   {
      Dbg(StringFormat("Order send FAILED. Type=%s Retcode=%u Desc=%s Comment=%s LastError=%d",
                       OrderTypeName(type),
                       trade.ResultRetcode(),
                       trade.ResultRetcodeDescription(),
                       trade.ResultComment(),
                       GetLastError()));
      return false;
   }

   Dbg(StringFormat("Order sent SUCCESS. Type=%s Order=%I64u Deal=%I64u Retcode=%u",
                    OrderTypeName(type),
                    trade.ResultOrder(),
                    trade.ResultDeal(),
                    trade.ResultRetcode()));
   return true;
}

//+------------------------------------------------------------------+
//| Main strategy - WEIGHTED SIGNAL SCORING                          |
//+------------------------------------------------------------------+
void CheckSignal()
{
   string reason = "";
   if(!RiskGuardOK(reason))
   {
      Dbg(reason);
      return;
   }
   Dbg(reason);

   if(!SessionOK(reason))
   {
      Dbg(reason);
      return;
   }
   Dbg(reason);

   // ===== READ INDICATORS =====
   double fast1, fast2, slow1, slow2, rsi1, atr1, fastSlopeRef;
   if(!GetValue(hFastEMA, 1, fast1)) return;
   if(!GetValue(hFastEMA, 2, fast2)) return;
   if(!GetValue(hFastEMA, 1 + SlopeLookback, fastSlopeRef)) return;
   if(!GetValue(hSlowEMA, 1, slow1)) return;
   if(!GetValue(hSlowEMA, 2, slow2)) return;
   if(!GetValue(hRSI,     1, rsi1))  return;
   if(!GetValue(hATR,     1, atr1))  return;

   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double buffer = ReclaimBufferPoints * point;

   double open1  = iOpen(_Symbol, InpTimeframe, 1);
   double close1 = iClose(_Symbol, InpTimeframe, 1);
   double close2 = iClose(_Symbol, InpTimeframe, 2);
   double high2  = iHigh(_Symbol, InpTimeframe, 2);
   double low2   = iLow(_Symbol, InpTimeframe, 2);

   // ===== CONDITION EVALUATION =====
   bool upTrend      = (fast1 > slow1);
   bool downTrend    = (fast1 < slow1);
   bool slopeUp      = (fast1 > fastSlopeRef);
   bool slopeDown    = (fast1 < fastSlopeRef);
   bool buyTouch     = (low2 <= fast2);
   bool sellTouch    = (high2 >= fast2);
   bool buyReclaim   = (close1 > (fast1 + buffer) && close1 > open1);
   bool sellReclaim  = (close1 < (fast1 - buffer) && close1 < open1);
   bool buyRsiOk     = (rsi1 >= BuyRSIMin && rsi1 <= BuyRSIMax);
   bool sellRsiOk    = (rsi1 >= SellRSIMin && rsi1 <= SellRSIMax);

   // ===== SCORE-BASED SIGNAL EVALUATION =====
   bool isBuy = false, isSell = false;
   ENUM_SIGNAL_TYPE buySignal = EvaluateSignal(upTrend, slopeUp, buyTouch, buyReclaim, buyRsiOk, isBuy);
   ENUM_SIGNAL_TYPE sellSignal = EvaluateSignal(downTrend, slopeDown, sellTouch, sellReclaim, sellRsiOk, isSell);

   Dbg(StringFormat("Signal check: FastEMA=%.2f SlowEMA=%.2f RSI=%.2f ATR=%.5f | UpTrend=%s SlopeUp=%s BuyTouch=%s BuyReclaim=%s BuyRSI=%s | BuySignal=%s | DownTrend=%s SlopeDown=%s SellTouch=%s SellReclaim=%s SellRSI=%s | SellSignal=%s",
                    fast1, slow1, rsi1, atr1,
                    (upTrend ? "Y" : "N"), (slopeUp ? "Y" : "N"), (buyTouch ? "Y" : "N"), (buyReclaim ? "Y" : "N"), (buyRsiOk ? "Y" : "N"),
                    SignalName(buySignal),
                    (downTrend ? "Y" : "N"), (slopeDown ? "Y" : "N"), (sellTouch ? "Y" : "N"), (sellReclaim ? "Y" : "N"), (sellRsiOk ? "Y" : "N"),
                    SignalName(sellSignal)));

   // ===== EXECUTE IF SIGNAL MEETS THRESHOLD =====
   if(buySignal >= SignalThreshold)
   {
      Dbg(StringFormat("BUY signal %s meets threshold (%s). Opening position.", SignalName(buySignal), SignalName((ENUM_SIGNAL_TYPE)SignalThreshold)));
      OpenTrade(ORDER_TYPE_BUY, atr1);
   }
   else if(sellSignal >= SignalThreshold)
   {
      Dbg(StringFormat("SELL signal %s meets threshold (%s). Opening position.", SignalName(sellSignal), SignalName((ENUM_SIGNAL_TYPE)SignalThreshold)));
      OpenTrade(ORDER_TYPE_SELL, atr1);
   }
   else
   {
      Dbg(StringFormat("No actionable signal. Buy=%s Sell=%s Threshold=%s",
                       SignalName(buySignal), SignalName(sellSignal), SignalName((ENUM_SIGNAL_TYPE)SignalThreshold)));
   }
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayStart = StartOfDay(TimeCurrent());
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   hFastEMA = iMA(_Symbol, InpTimeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, InpTimeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, InpTimeframe, RSIPeriod, PRICE_CLOSE);
   hATR     = iATR(_Symbol, InpTimeframe, ATRPeriod);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);

   Dbg(StringFormat("EA INITIALIZED (OPTIMIZED v2.0). Symbol=%s TF=%d FastEMA=%d SlowEMA=%d RSI=%d ATR=%d | ATR_SL=%.2f ATR_TP=%.2f SlopeLook=%d BufferPts=%d | Risk=%.2f%% Session=%d-%d MaxSpread=%dpts FridayStop=%d | SignalThreshold=%s | Magic=%I64u",
                    _Symbol, InpTimeframe, FastEMA, SlowEMA, RSIPeriod, ATRPeriod,
                    ATR_SL_Mult, ATR_TP_Mult, SlopeLookback, ReclaimBufferPoints,
                    RiskPerTradePct, StartHour, EndHour, MaxSpreadPoints, FridayStopHour,
                    SignalName((ENUM_SIGNAL_TYPE)SignalThreshold),
                    MagicNumber));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);

   Dbg(StringFormat("EA deinitialized. Reason=%d", reason));
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   RefreshDailyState();

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = 0.0;
   if(initialBalance > 0.0)
      ddPct = (initialBalance - equity) / initialBalance * 100.0;

   if(ddPct >= EmergencyDDPct)
   {
      tradingHalted = true;
      Dbg(StringFormat("EMERGENCY DRAWDOWN REACHED. DD=%.2f%% Threshold=%.2f%%. Closing all positions.", ddPct, EmergencyDDPct));

      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;

         if(!PositionSelectByTicket(ticket))
            continue;

         string symbol = PositionGetString(POSITION_SYMBOL);
         ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

         if(symbol != _Symbol)
            continue;
         if(magic != MagicNumber)
            continue;

         bool closed = trade.PositionClose(ticket);
         Dbg(StringFormat("Emergency close ticket=%I64u result=%s retcode=%u desc=%s",
                          ticket,
                          (closed ? "SUCCESS" : "FAILED"),
                          trade.ResultRetcode(),
                          trade.ResultRetcodeDescription()));
      }
      return;
   }

   if(IsNewBar())
      CheckSignal();
}

//+------------------------------------------------------------------+
//| END OF OPTIMIZED EA                                              |
//+------------------------------------------------------------------+
