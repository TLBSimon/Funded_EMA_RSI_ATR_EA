//+------------------------------------------------------------------+
//| Funded_EMA_RSI_ATR_EA_Fixed.mq5                                  |
//| OPTIMIZED version - ALL BUGS FIXED                               |
//| Production-ready Expert Advisor for XAUUSD M15                   |
//+------------------------------------------------------------------+
#property strict
#property version   "2.01"
#property description "Optimized EMA/RSI/ATR - Fixed compilation errors"

#include <Trade/Trade.mqh>
CTrade trade;

//--------------------------- ENUMS (MUST BE BEFORE INPUTS) ---------
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
input ENUM_SIGNAL_THRESHOLD SignalThreshold = SIGNAL_MEDIUM;

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
      lastHistoryCheck = 0;
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
   for(int i = PositionsTotal() - 1; i >= 0; i--)
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
//| Count today's deals - OPTIMIZED WITH CACHING                    |
//+------------------------------------------------------------------+
int CountTodayEntries()
{
   datetime now = TimeCurrent();
   
   if(now - lastHistoryCheck < HISTORY_CACHE_SECONDS)
      return cachedTradesCount;

   datetime from = StartOfDay(now);
   if(!HistorySelect(from, now))
   {
      Dbg("HistorySelect failed while counting today's entries.");
      return cachedTradesCount;
   }

   int count = 0;
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
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

   lastHistoryCheck = now;
   cachedTradesCount = count;
   
   Dbg(StringFormat("Trades count refreshed. Count=%d CacheTTL=%d sec", count, HISTORY_CACHE_SECONDS));
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
      reason = StringFormat("Blocked by daily loss. DailyLoss=%.2f%% Max=%.2f%%", dailyLossPct, MaxDailyLossPct);
      return false;
   }

   if(totalDDPct >= MaxTotalDDPct)
   {
      tradingHalted = true;
      reason = StringFormat("Blocked by total DD. TotalDD=%.2f%% Max=%.2f%%", totalDDPct, MaxTotalDDPct);
      return false;
   }

   if(totalDDPct >= EmergencyDDPct)
   {
      tradingHalted = true;
      reason = StringFormat("Emergency DD reached. TotalDD=%.2f%%", totalDDPct);
      return false;
   }

   if(tradingHalted)
   {
      reason = "Trading halted.";
      return false;
   }

   int openPositions = CountOpenPositions();
   if(openPositions >= MaxOpenPositions)
   {
      reason = StringFormat("Max positions reached. Open=%d", openPositions);
      return false;
   }

   tradesToday = CountTodayEntries();
   if(tradesToday >= MaxTradesPerDay)
   {
      reason = StringFormat("Max daily trades reached. Today=%d", tradesToday);
      return false;
   }

   reason = StringFormat("Risk OK. Equity=%.2f DD=%.2f%% Trades=%d", equity, totalDDPct, tradesToday);
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
      reason = StringFormat("Outside session. Hour=%d", dt.hour);
      return false;
   }

   if(AvoidFridayLate && dt.day_of_week == 5 && dt.hour >= FridayStopHour)
   {
      reason = StringFormat("Friday late avoided. Hour=%d", dt.hour);
      return false;
   }

   reason = "Session OK";
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
      Dbg(StringFormat("New bar at %s", TimeToString(t, TIME_DATE|TIME_MINUTES)));
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Read indicator value - OPTIMIZED                                |
//+------------------------------------------------------------------+
bool GetValue(int handle, int shift, double &value)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(handle, 0, shift, 1, buf);
   if(copied != 1)
   {
      Dbg(StringFormat("CopyBuffer failed. Handle=%d Shift=%d Error=%d", handle, shift, GetLastError()));
      return false;
   }
   value = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Calculate volume - PRECISE                                       |
//+------------------------------------------------------------------+
double CalculateVolume(ENUM_ORDER_TYPE type, double entry, double sl)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTradePct / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(point <= 0.0 || tickValue <= 0.0)
   {
      Dbg(StringFormat("Invalid params. Point=%.8f TickValue=%.8f", point, tickValue));
      return 0.0;
   }

   double slPips = MathAbs(entry - sl) / point;
   if(slPips <= 0.0)
   {
      Dbg(StringFormat("Invalid SL. Entry=%.5f SL=%.5f", entry, sl));
      return 0.0;
   }

   double volume = riskMoney / (slPips * tickValue);

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
      Dbg(StringFormat("Volume too small. Calc=%.4f Min=%.4f", volume, minv));
      return 0.0;
   }

   int volDigits = 2;
   if(step == 1.0)      volDigits = 0;
   else if(step == 0.1) volDigits = 1;
   else if(step == 0.01) volDigits = 2;
   else if(step == 0.001) volDigits = 3;

   volume = NormalizeDouble(volume, volDigits);

   Dbg(StringFormat("Volume=%.3f (Risk=%.2f RiskMoney=%.2f SLPips=%.2f)", volume, RiskPerTradePct, riskMoney, slPips));
   return volume;
}

//+------------------------------------------------------------------+
//| Weighted signal scoring                                          |
//+------------------------------------------------------------------+
ENUM_SIGNAL_TYPE EvaluateSignal(bool upTrend, bool slopeUp, bool buyTouch,
                                 bool buyReclaim, bool buyRsiOk)
{
   int score = 0;

   if(!upTrend)
      return NO_SIGNAL;

   score = 2;

   if(slopeUp)
      score++;
   if(buyTouch)
      score++;

   if(buyRsiOk)
      score++;
   if(buyReclaim)
      score++;

   if(score >= 4)
      return STRONG_SIGNAL;
   if(score >= 3)
      return MEDIUM_SIGNAL;
   if(score >= 2)
      return WEAK_SIGNAL;

   return NO_SIGNAL;
}

//+------------------------------------------------------------------+
//| Open trade - WITH VALIDATION                                    |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double atr)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0)
   {
      Dbg(StringFormat("Invalid quotes. Ask=%.5f Bid=%.5f", ask, bid));
      return false;
   }

   if(ask <= bid)
   {
      Dbg(StringFormat("Bad spread. Ask=%.5f Bid=%.5f", ask, bid));
      return false;
   }

   double spreadPts = (ask - bid) / point;
   if(spreadPts > MaxSpreadPoints)
   {
      Dbg(StringFormat("Spread too high. Spread=%.2f pts", spreadPts));
      return false;
   }

   double entry = (type == ORDER_TYPE_BUY ? ask : bid);
   double slDistance = atr * ATR_SL_Mult;
   double tpDistance = atr * ATR_TP_Mult;

   if(slDistance <= 0.0 || tpDistance <= 0.0)
   {
      Dbg(StringFormat("Invalid ATR. ATR=%.5f", atr));
      return false;
   }

   double rr = tpDistance / slDistance;
   if(rr < MinRR)
   {
      Dbg(StringFormat("RR too low. RR=%.2f MinRR=%.2f", rr, MinRR));
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

   long stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopLevelPts * point;

   if(MathAbs(entry - sl) < minStopDistance)
   {
      if(type == ORDER_TYPE_BUY)
         sl = entry - minStopDistance;
      else
         sl = entry + minStopDistance;
   }

   if(MathAbs(tp - entry) < minStopDistance)
   {
      if(type == ORDER_TYPE_BUY)
         tp = entry + minStopDistance;
      else
         tp = entry - minStopDistance;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double volume = CalculateVolume(type, entry, sl);
   if(volume <= 0.0)
   {
      Dbg("Volume invalid.");
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   Dbg(StringFormat("Order: %s Entry=%.2f SL=%.2f TP=%.2f Vol=%.3f RR=%.2f", 
                    OrderTypeName(type), entry, sl, tp, volume, rr));

   bool ok = false;
   ResetLastError();

   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(volume, _Symbol, 0.0, sl, tp, "BUY");
   else
      ok = trade.Sell(volume, _Symbol, 0.0, sl, tp, "SELL");

   if(!ok)
   {
      Dbg(StringFormat("Order FAILED. Retcode=%u Error=%d", trade.ResultRetcode(), GetLastError()));
      return false;
   }

   Dbg(StringFormat("Order SUCCESS. Retcode=%u Deal=%I64u", trade.ResultRetcode(), trade.ResultDeal()));
   return true;
}

//+------------------------------------------------------------------+
//| Main strategy                                                    |
//+------------------------------------------------------------------+
void CheckSignal()
{
   string reason = "";
   if(!RiskGuardOK(reason))
   {
      Dbg(reason);
      return;
   }

   if(!SessionOK(reason))
   {
      Dbg(reason);
      return;
   }

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

   ENUM_SIGNAL_TYPE buySignal = EvaluateSignal(upTrend, slopeUp, buyTouch, buyReclaim, buyRsiOk);
   ENUM_SIGNAL_TYPE sellSignal = EvaluateSignal(downTrend, slopeDown, sellTouch, sellReclaim, sellRsiOk);

   Dbg(StringFormat("FastEMA=%.2f SlowEMA=%.2f RSI=%.2f BuySignal=%s SellSignal=%s", 
                    fast1, slow1, rsi1, SignalName(buySignal), SignalName(sellSignal)));

   if(buySignal >= SignalThreshold)
   {
      Dbg(StringFormat("BUY: %s >= %d", SignalName(buySignal), SignalThreshold));
      OpenTrade(ORDER_TYPE_BUY, atr1);
   }
   else if(sellSignal >= SignalThreshold)
   {
      Dbg(StringFormat("SELL: %s >= %d", SignalName(sellSignal), SignalThreshold));
      OpenTrade(ORDER_TYPE_SELL, atr1);
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

   Dbg(StringFormat("EA INITIALIZED. Symbol=%s TF=%d FastEMA=%d SlowEMA=%d RSI=%d ATR=%d Risk=%.2f%%",
                    _Symbol, InpTimeframe, FastEMA, SlowEMA, RSIPeriod, ATRPeriod, RiskPerTradePct));

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
      Dbg(StringFormat("EMERGENCY DD. DD=%.2f%%", ddPct));

      for(int i = PositionsTotal() - 1; i >= 0; i--)
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

         trade.PositionClose(ticket);
         Dbg(StringFormat("Emergency close ticket=%I64u", ticket));
      }
      return;
   }

   if(IsNewBar())
      CheckSignal();
}

//+------------------------------------------------------------------+
//| END OF FIXED EA v2.01                                            |
//+------------------------------------------------------------------+
