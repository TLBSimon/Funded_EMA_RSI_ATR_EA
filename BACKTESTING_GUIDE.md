# 📊 BACKTESTING & OPTIMIZATION GUIDE
# Funded_EMA_RSI_ATR_EA - Parameter Testing & Tuning

## 🎯 RECOMMENDED PARAMETER RANGES FOR OPTIMIZATION

### **1. TREND INDICATORS (EMA Periods)**

**Purpose:** Capture trend direction and pullback depth

| Parameter | Min | Default | Max | Step | Notes |
|-----------|-----|---------|-----|------|-------|
| **FastEMA** | 20 | 40 | 80 | 5 | Faster trend detection. Lower = more trades, higher sensitivity |
| **SlowEMA** | 150 | 220 | 300 | 20 | Main trend filter. Higher = fewer false signals |

**Optimization Strategy:**
- **Conservative:** FastEMA=30, SlowEMA=200 (fewer trades, high quality)
- **Balanced:** FastEMA=40, SlowEMA=220 (default, good balance)
- **Aggressive:** FastEMA=50, SlowEMA=250 (more trades, more risk)

**Test sequence:**
```
Round 1: FastEMA [30, 40, 50] × SlowEMA [180, 220, 260]
Round 2: Narrow to best 2-3 combinations, test ±5 increments
```

---

### **2. RSI FILTER (Pullback Confirmation)**

**Purpose:** Confirm pullback reversal zones

| Parameter | Min | Default | Max | Step | Notes |
|-----------|-----|---------|-----|------|-------|
| **RSIPeriod** | 12 | 18 | 25 | 1 | Lower = more sensitive, higher = smoother |
| **BuyRSIMin** | 45 | 55 | 60 | 2.5 | Entry zone bottom (pullback bottom) |
| **BuyRSIMax** | 65 | 70 | 75 | 2.5 | Entry zone top (before overbought) |
| **SellRSIMin** | 25 | 35 | 40 | 2.5 | Sell zone bottom (before oversold) |
| **SellRSIMax** | 45 | 47.5 | 55 | 2.5 | Sell zone top (pullback top) |

**Optimization Strategy:**
- **Conservative (fewer trades, high quality):**
  - BuyRSIMin=55, BuyRSIMax=68
  - SellRSIMin=32, SellRSIMax=47
  
- **Balanced (default):**
  - BuyRSIMin=55, BuyRSIMax=70
  - SellRSIMin=35, SellRSIMax=47.5
  
- **Aggressive (more trades):**
  - BuyRSIMin=50, BuyRSIMax=72
  - SellRSIMin=28, SellRSIMax=50

**Test sequence:**
```
Round 1: Test RSIPeriod [12, 15, 18, 21] separately
Round 2: For best RSIPeriod, test RSI ranges ±5 from default
Round 3: Fine-tune ±2.5 on best combination
```

---

### **3. ATR RISK (Position Sizing & Exits)**

**Purpose:** Dynamic stop-loss and take-profit sizing

| Parameter | Min | Default | Max | Step | Notes |
|-----------|-----|---------|-----|------|-------|
| **ATRPeriod** | 40 | 60 | 80 | 5 | Period for volatility measurement |
| **ATR_SL_Mult** | 1.0 | 1.4 | 2.0 | 0.1 | Stop-loss distance (×ATR) |
| **ATR_TP_Mult** | 2.0 | 2.8 | 4.0 | 0.2 | Take-profit distance (×ATR) |

**Risk/Reward Ratios (TP/SL):**
- **Conservative:** ATR_SL_Mult=1.6, ATR_TP_Mult=3.2 → RR=2.0
- **Balanced:** ATR_SL_Mult=1.4, ATR_TP_Mult=2.8 → RR=2.0
- **Tight:** ATR_SL_Mult=1.2, ATR_TP_Mult=2.4 → RR=2.0

**Test sequence:**
```
Round 1: Keep MinRR=2.0, test ATRPeriod [40, 60, 80]
Round 2: For best ATRPeriod, test combinations that maintain RR≥2.0
Round 3: Fine-tune multipliers by 0.1-0.2 increments
```

**💡 Pro Tip:** Higher ATR_SL_Mult = fewer SL hits but larger losses; Lower = more SL hits but tighter losses

---

### **4. PULLBACK FILTERS (Signal Confirmation)**

| Parameter | Min | Default | Max | Step | Notes |
|-----------|-----|---------|-----|------|-------|
| **SlopeLookback** | 2 | 3 | 5 | 1 | Bars back for momentum slope check |
| **ReclaimBufferPoints** | 5 | 10 | 20 | 5 | Points above EMA for reclaim confirmation |

**Optimization Strategy:**
- **Conservative:** SlopeLookback=4, ReclaimBufferPoints=15
- **Balanced:** SlopeLookback=3, ReclaimBufferPoints=10
- **Aggressive:** SlopeLookback=2, ReclaimBufferPoints=5

---

### **5. RISK MANAGEMENT (Account Protection)**

| Parameter | Conservative | Balanced | Aggressive | Notes |
|-----------|--------------|----------|-----------|-------|
| **RiskPerTradePct** | 0.30% | 0.50% | 0.75% | Risk per trade (of equity) |
| **MaxDailyLossPct** | 1.00% | 2.00% | 3.00% | Stop trading at daily loss |
| **MaxTotalDDPct** | 3.00% | 5.00% | 7.00% | Stop trading at total drawdown |
| **MaxTradesPerDay** | 10 | 20 | 30 | Max entries per day |
| **MaxOpenPositions** | 1 | 1 | 2 | Max simultaneous positions |

**⚠️ CRITICAL:** For funded account compliance, use:
- **RiskPerTradePct = 0.50%** (standard for prop firms)
- **MaxDailyLossPct = 2.00%** (most funded accounts require <2%)
- **MaxTotalDDPct = 5.00%** (common challenge rules)

---

## 🧪 BACKTESTING WORKFLOW

### **Step 1: Initial Scan (1 week)**
```
Test all 9 EMA combinations × all 3 RSI presets
Keep top 5 by: Profit Factor + Win Rate
```

### **Step 2: RSI Fine-tuning (3 days)**
```
For each top 5 EMA combo, optimize RSI ranges ±5
Keep top 10 by: Sharpe Ratio (risk-adjusted returns)
```

### **Step 3: ATR Optimization (3 days)**
```
For each top 10 combo, test 6 ATR multiplier pairs
Keep top 5 by: Max Drawdown + Profit Factor
```

### **Step 4: Risk Parameters (1 day)**
```
For each top 5 combo, test RiskPerTradePct [0.25, 0.50, 0.75]
Final selection: Largest Win Rate with Equity Curve Consistency
```

### **Step 5: Live Paper Trading (1-2 weeks)**
```
Run top 3 configs on LIVE quotes (paper money)
Verify: Signal quality + Execution speed + Slippage reality
```

---

## 📈 BACKTEST SUCCESS METRICS

| Metric | Target | Action if Failed |
|--------|--------|------------------|
| **Win Rate** | >50% | Increase RSI range (too strict) |
| **Profit Factor** | >1.5 | Check SL/TP ratio, adjust ATR |
| **Max Drawdown** | <3% | Reduce RiskPerTradePct or MaxTradesPerDay |
| **Sharpe Ratio** | >1.0 | Increase SlopeLookback (fewer false entries) |
| **Trades Per Month** | 40-80 | Balance signal quality vs. opportunity |
| **Average Win/Loss Ratio** | >1.5 | Adjust ATR_TP_Mult upward |

---

## 🔧 QUICK START: PARAMETER SETS

### **SET A: Conservative (Prop Firm Safe)**
```
FastEMA=35, SlowEMA=200, RSIPeriod=18
BuyRSIMin=55, BuyRSIMax=68, SellRSIMin=32, SellRSIMax=47
ATRPeriod=60, ATR_SL_Mult=1.5, ATR_TP_Mult=3.0
SlopeLookback=4, ReclaimBufferPoints=12
RiskPerTradePct=0.50%, MaxDailyLossPct=2.00%
SignalThreshold=SIGNAL_MEDIUM
```
**Expected:** 45-55% win rate, low volatility, 30-50 trades/month

---

### **SET B: Balanced (Best Starting Point)**
```
FastEMA=40, SlowEMA=220, RSIPeriod=18
BuyRSIMin=55, BuyRSIMax=70, SellRSIMin=35, SellRSIMax=47.5
ATRPeriod=60, ATR_SL_Mult=1.4, ATR_TP_Mult=2.8
SlopeLookback=3, ReclaimBufferPoints=10
RiskPerTradePct=0.50%, MaxDailyLossPct=2.00%
SignalThreshold=SIGNAL_MEDIUM
```
**Expected:** 50-55% win rate, balanced risk/reward, 50-70 trades/month

---

### **SET C: Aggressive (Higher Risk)**
```
FastEMA=50, SlowEMA=250, RSIPeriod=15
BuyRSIMin=50, BuyRSIMax=72, SellRSIMin=28, SellRSIMax=50
ATRPeriod=45, ATR_SL_Mult=1.2, ATR_TP_Mult=2.4
SlopeLookback=2, ReclaimBufferPoints=5
RiskPerTradePct=0.50%, MaxDailyLossPct=2.00%
SignalThreshold=SIGNAL_WEAK
```
**Expected:** 48-52% win rate, more trades, higher volatility, 80-120 trades/month

---

## 🚀 HOW TO USE THE PYTHON BACKTESTER

### **Prerequisites:**
```bash
pip install pandas numpy requests
```

### **Configuration (in backtest_engine.py):**
```python
API_KEY = "BLAe3lvgud7mQVGPlPmRNEFM9MaZG7tiW/4/g/lXQF"
SYMBOL = "XAUUSD"
LOOKBACK_DAYS = 730  # 2 years
```

### **Run the backtest:**
```bash
python backtest_engine.py
```

### **Output files:**
- `backtest_results/backtest_results.csv` - Full detailed results
- `backtest_results/top_3_configs.json` - Best 3 configurations with metrics

---

## 📈 BACKTEST SUCCESS METRICS

### What to look for in results:

**Good Configuration:**
```
Profit Factor: > 1.5
Win Rate: 50-60%
Max Drawdown: < 3-4%
Sharpe Ratio: > 0.8
Consecutive Wins: 5-10 trades typical
Largest Win vs Largest Loss: 2:1 minimum
```

**Warning Signs (Overfitted):**
```
Win Rate: > 75% (unrealistic)
Profit Factor: > 3.0 (likely curve-fit)
Only works on specific months
Breaks down on recent data
```

---

## 🎓 INTERPRETATION GUIDE

### **Profit Factor = Gross Profit / Gross Loss**
- **< 1.0** = Losing strategy, REJECT
- **1.0 - 1.5** = Break even to marginal, CAUTION
- **1.5 - 2.0** = GOOD, this is target zone
- **2.0 - 3.0** = EXCELLENT
- **> 3.0** = Possibly overfit, verify on different data

### **Win Rate**
- Expected for mechanical systems: 45-60%
- < 40% = Need larger TP or better entries
- > 70% = Likely small wins + occasional large loss
- **Target: 50-55%** with 2:1 RR ratio

### **Max Drawdown**
- **< 2%** = Very conservative
- **2-4%** = Good balance
- **4-6%** = Acceptable for prop firms
- **> 6%** = Too risky

### **Sharpe Ratio** (Risk-Adjusted Returns)
- **< 0.5** = Poor risk/return
- **0.5 - 1.0** = Acceptable
- **1.0 - 2.0** = GOOD
- **> 2.0** = Excellent

---

## 📋 PARAMETER TESTING CHECKLIST

### Pre-Backtest:
- [ ] Copy EA to `MQL5/Experts/` folder
- [ ] Verify API key is valid
- [ ] Download XAUUSD M15 history (1-12 months minimum)
- [ ] Set broker spread in tester (typical: 0.3-0.5 for XAUUSD)
- [ ] Set account size to match your funded account
- [ ] Enable "Visual" mode for first test (to verify signals)

### During Backtest:
- [ ] Watch for entry consistency (signals should align with price action)
- [ ] Monitor signal timing (should trigger on bar close)
- [ ] Check P&L distribution (should be random, not clustered)
- [ ] Verify SL/TP execution (must hit at calculated levels)
- [ ] Monitor equity curve (should trend up with occasional dips)

### Post-Backtest Analysis:
- [ ] Export results to CSV
- [ ] Calculate: Profit Factor = Gross Profit / Gross Loss
- [ ] Calculate: Sharpe = (Avg Return - Risk-Free Rate) / Std Dev
- [ ] Plot equity curve (should be smooth, not spiky)
- [ ] Review largest losses (should be near max 1-2% each)
- [ ] Check trade distribution by hour/day (should be consistent)

---

## 💡 OPTIMIZATION TIPS

1. **Start Wide, Narrow Down:**
   - Week 1: Test extreme ranges (FastEMA 20-80)
   - Week 2: Focus on top 5 parameters
   - Week 3: Fine-tune best combo by ±2%

2. **Avoid Overfitting:**
   - Don't optimize on weekends (gold behavior changes)
   - Test on out-of-sample data (backtest 6mo, verify on next 3mo)
   - Ensure same logic holds on 1H and 4H timeframes

3. **Watch for Curve-Fitting:**
   - If results are "too good" (>70% win rate), parameters are overfit
   - Target realistic metrics: 50-60% win rate, 1.5-2.0 profit factor

4. **Document Everything:**
   - Save each backtest result with timestamp
   - Note market conditions (trending vs. range-bound)
   - Track parameter changes and their impact

5. **Market Regimes:**
   - Test on trending markets (Jan-Mar, Jul-Sep for gold)
   - Test on choppy markets (May-Jun, Dec-Jan)
   - Verify parameters work in BOTH regimes

---

## 📊 SAMPLE OPTIMIZATION LOG

```
Date: 2026-09-08
Backtest Period: 2026-06-01 to 2026-09-08 (3 months)
Symbol: XAUUSD | TF: M15
Initial Deposit: $10,000

TEST 1 - FastEMA Scan:
├─ FastEMA=20: Win%=48%, PF=1.3, MaxDD=4.2%
├─ FastEMA=30: Win%=52%, PF=1.6, MaxDD=3.8% ⭐
├─ FastEMA=40: Win%=51%, PF=1.5, MaxDD=3.5% ⭐
└─ FastEMA=50: Win%=49%, PF=1.2, MaxDD=5.1%

TEST 2 - RSI Fine-tuning on FastEMA=40:
├─ RSI 50-70: Win%=51%, PF=1.5, MaxDD=3.5%
├─ RSI 55-70: Win%=52%, PF=1.6, MaxDD=3.2% ⭐⭐
└─ RSI 55-75: Win%=50%, PF=1.4, MaxDD=4.1%

TEST 3 - ATR Multipliers on Best Config:
├─ SL=1.4, TP=2.8: Win%=52%, PF=1.6, MaxDD=3.2% ✅ FINAL
└─ SL=1.5, TP=3.0: Win%=51%, PF=1.55, MaxDD=3.1%

FINAL SELECTED CONFIG:
FastEMA=40, SlowEMA=220, RSIPeriod=18
BuyRSIMin=55, BuyRSIMax=70
ATRPeriod=60, ATR_SL_Mult=1.4, ATR_TP_Mult=2.8
```

---

## ⚠️ COMMON PITFALLS

| Pitfall | Impact | Solution |
|---------|--------|----------|
| Testing only 1 month | Overfitting to single trend | Test 6-12 months |
| Wrong spread value | Unrealistic profits | Use actual broker spread |
| Visual mode ON for full backtest | 1000x slower testing | Use ON only for verification |
| Testing wrong timeframe | Signals won't match live | Verify TF = InpTimeframe |
| Too aggressive risk | Account blowup risk | Start with 0.5% per trade |
| Ignoring commission | 15-20% profit loss | Add 0.5-1 pip commission if applicable |
| Weekend testing | Gold behaves differently | Focus on trading hours only |

---

## 🎓 NEXT STEPS

1. **Day 1:** Run initial backtest with SET B parameters
2. **Day 2:** Analyze results, identify 2-3 areas for improvement
3. **Day 3-5:** Optimize identified weak spots
4. **Day 6-8:** Validate on fresh 3-month out-of-sample period
5. **Day 9-22:** Paper trade for 2 weeks on live quotes
6. **Day 23+:** Go live with small position size (0.1 lot)

---

## 📞 TROUBLESHOOTING

**Q: My profit factor is 1.0, what's wrong?**
A: Strategy is breaking even. Try:
- Widen RSI range (currently too strict on entries)
- Reduce ATR_SL_Mult (SL too wide, losing money on losers)
- Increase ATR_TP_Mult (TP too tight, not capturing enough wins)

**Q: 80% win rate but low profit - help?**
A: Classic issue: many small wins, few large losses
- Solution: Increase ATR_TP_Mult by 0.3-0.5
- Or: Reduce ATR_SL_Mult by 0.1-0.2
- Result: Fewer trades, but better R:R ratio

**Q: Backtests great but fails live - why?**
A: Overfitting or market regime change
- Always test on OUT-OF-SAMPLE data
- Verify on different market phases
- Use paper trading before going live
- Start with 0.1 lot size for 1-2 weeks

---

**For detailed backtesting results, run: `python backtest_engine.py`**
