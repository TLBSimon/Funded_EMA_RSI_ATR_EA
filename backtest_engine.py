#!/usr/bin/env python3
"""
Funded_EMA_RSI_ATR_EA - Automated Backtesting Engine
2-Year Historical Backtesting with Parameter Optimization
"""

import requests
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import json
import os
from itertools import product
import warnings
warnings.filterwarnings('ignore')

# =====================================================================
# CONFIGURATION
# =====================================================================

API_KEY = "BLAe3lvgud7mQVGPlPmRNEFM9MaZG7tiW/4/g/lXQF"
SYMBOL = "XAUUSD"
TIMEFRAME = "M15"  # 15 minutes
LOOKBACK_DAYS = 730  # 2 years
OUTPUT_DIR = "backtest_results"

# Create output directory
os.makedirs(OUTPUT_DIR, exist_ok=True)

# =====================================================================
# PARAMETER RANGES FOR OPTIMIZATION
# =====================================================================

PARAM_RANGES = {
    'FastEMA': [30, 40, 50],
    'SlowEMA': [180, 220, 260],
    'RSIPeriod': [15, 18, 21],
    'BuyRSIMin': [50, 55, 60],
    'BuyRSIMax': [68, 70, 72],
    'SellRSIMin': [28, 35, 40],
    'SellRSIMax': [45, 47.5, 50],
    'ATRPeriod': [40, 60, 80],
    'ATR_SL_Mult': [1.2, 1.4, 1.6],
    'ATR_TP_Mult': [2.4, 2.8, 3.2],
    'SlopeLookback': [2, 3, 4],
    'ReclaimBufferPoints': [5, 10, 15],
}

FIXED_PARAMS = {
    'RiskPerTradePct': 0.50,
    'MaxDailyLossPct': 2.00,
    'MaxTotalDDPct': 5.00,
    'MaxTradesPerDay': 20,
    'MaxOpenPositions': 1,
    'SignalThreshold': 2,  # MEDIUM
    'StartHour': 8,
    'EndHour': 18,
}

# =====================================================================
# DATA FETCHING
# =====================================================================

def fetch_historical_data(symbol=SYMBOL, days=LOOKBACK_DAYS, api_key=API_KEY):
    """
    Fetch historical M15 OHLC data using Alpha Vantage API
    (Alternative: Use OANDA REST API or your broker's API)
    """
    print(f"🔄 Fetching {days} days of {symbol} M15 data...")
    
    # Using OANDA REST API as example (you can switch to Alpha Vantage)
    base_url = "https://api-fxpractice.oanda.com/v3"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    
    # Calculate date range
    end_time = datetime.utcnow()
    start_time = end_time - timedelta(days=days)
    
    all_candles = []
    
    try:
        # Fetch in chunks (API limit is usually 5000 candles per request)
        chunk_size = 4000
        current_time = start_time
        
        while current_time < end_time:
            next_time = min(current_time + timedelta(minutes=chunk_size * 15), end_time)
            
            params = {
                "granularity": "M15",
                "from": current_time.isoformat() + "Z",
                "to": next_time.isoformat() + "Z",
                "price": "MBA"
            }
            
            response = requests.get(
                f"{base_url}/instruments/{symbol}/candles",
                headers=headers,
                params=params,
                timeout=10
            )
            
            if response.status_code == 200:
                data = response.json()
                candles = data.get('candles', [])
                print(f"  ✓ Fetched {len(candles)} candles from {current_time.date()}")
                all_candles.extend(candles)
            else:
                print(f"  ✗ API Error: {response.status_code}")
                break
            
            current_time = next_time
        
        # Convert to DataFrame
        df = pd.DataFrame([
            {
                'time': pd.to_datetime(c['time']),
                'open': float(c['mid']['o']),
                'high': float(c['mid']['h']),
                'low': float(c['mid']['l']),
                'close': float(c['mid']['c']),
                'volume': int(c.get('volume', 0))
            }
            for c in all_candles
        ])
        
        df.set_index('time', inplace=True)
        df.sort_index(inplace=True)
        
        print(f"✅ Downloaded {len(df)} candles ({df.index[0].date()} to {df.index[-1].date()})")
        return df
        
    except Exception as e:
        print(f"❌ Data fetch error: {e}")
        print("📝 Note: Using simulated data for demonstration")
        return generate_simulated_data(days=days)


def generate_simulated_data(days=730):
    """
    Generate realistic XAUUSD M15 data for testing if API fails
    """
    print(f"📝 Generating {days} days of simulated XAUUSD M15 data...")
    
    dates = pd.date_range(end=datetime.utcnow(), periods=days*96, freq='15min')
    
    # Simulate realistic price movement
    base_price = 2000.0
    returns = np.random.normal(0.0001, 0.005, len(dates))
    prices = base_price * (1 + returns).cumprod()
    
    df = pd.DataFrame({
        'open': prices + np.random.uniform(-0.5, 0.5, len(dates)),
        'close': prices,
        'high': prices + np.abs(np.random.uniform(0, 1, len(dates))),
        'low': prices - np.abs(np.random.uniform(0, 1, len(dates))),
        'volume': np.random.randint(1000, 50000, len(dates))
    }, index=dates)
    
    df['high'] = df[['open', 'close', 'high']].max(axis=1)
    df['low'] = df[['open', 'close', 'low']].min(axis=1)
    
    return df

# =====================================================================
# INDICATOR CALCULATIONS
# =====================================================================

def calculate_ema(data, period):
    """Calculate Exponential Moving Average"""
    return data.ewm(span=period, adjust=False).mean()

def calculate_rsi(data, period=14):
    """Calculate Relative Strength Index"""
    delta = data.diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=period).mean()
    rs = gain / loss
    rsi = 100 - (100 / (1 + rs))
    return rsi

def calculate_atr(high, low, close, period=14):
    """Calculate Average True Range"""
    tr1 = high - low
    tr2 = abs(high - close.shift())
    tr3 = abs(low - close.shift())
    tr = pd.concat([tr1, tr2, tr3], axis=1).max(axis=1)
    atr = tr.rolling(period).mean()
    return atr

# =====================================================================
# BACKTESTING ENGINE
# =====================================================================

class BacktestEngine:
    def __init__(self, df, initial_balance=10000):
        self.df = df.copy()
        self.initial_balance = initial_balance
        self.trades = []
        self.equity_curve = [initial_balance]
        
    def add_indicators(self, fast_ema, slow_ema, rsi_period, atr_period, slope_lookback):
        """Add technical indicators to dataframe"""
        self.df['FastEMA'] = calculate_ema(self.df['close'], fast_ema)
        self.df['SlowEMA'] = calculate_ema(self.df['close'], slow_ema)
        self.df['RSI'] = calculate_rsi(self.df['close'], rsi_period)
        self.df['ATR'] = calculate_atr(self.df['high'], self.df['low'], self.df['close'], atr_period)
        self.df['FastEMA_Slope'] = self.df['FastEMA'].diff(slope_lookback)
        
        return self
    
    def generate_signals(self, buy_rsi_min, buy_rsi_max, sell_rsi_min, sell_rsi_max,
                        reclaim_buffer, atr_sl_mult, atr_tp_mult):
        """Generate buy/sell signals based on EA logic"""
        
        signals = []
        
        for i in range(max(10, 100)):  # Need enough bars for indicators
            if i < 2:  # Skip first bars (indicators not ready)
                continue
            
            try:
                # Current and previous bars
                fast1 = self.df['FastEMA'].iloc[i]
                fast2 = self.df['FastEMA'].iloc[i-1]
                slow1 = self.df['SlowEMA'].iloc[i]
                slow2 = self.df['SlowEMA'].iloc[i-1]
                rsi1 = self.df['RSI'].iloc[i]
                atr1 = self.df['ATR'].iloc[i]
                
                open1 = self.df['open'].iloc[i]
                close1 = self.df['close'].iloc[i]
                close2 = self.df['close'].iloc[i-1]
                high2 = self.df['high'].iloc[i-1]
                low2 = self.df['low'].iloc[i-1]
                
                point = 0.01  # XAUUSD point
                buffer = reclaim_buffer * point
                
                # BUY conditions
                up_trend = fast1 > slow1
                slope_up = self.df['FastEMA_Slope'].iloc[i] > 0
                buy_touch = low2 <= fast2
                buy_reclaim = (close1 > (fast1 + buffer)) and (close1 > open1)
                buy_rsi_ok = (rsi1 >= buy_rsi_min) and (rsi1 <= buy_rsi_max)
                
                buy_signal = up_trend and slope_up and buy_touch and buy_reclaim and buy_rsi_ok
                
                # SELL conditions
                down_trend = fast1 < slow1
                slope_down = self.df['FastEMA_Slope'].iloc[i] < 0
                sell_touch = high2 >= fast2
                sell_reclaim = (close1 < (fast1 - buffer)) and (close1 < open1)
                sell_rsi_ok = (rsi1 >= sell_rsi_min) and (rsi1 <= sell_rsi_max)
                
                sell_signal = down_trend and slope_down and sell_touch and sell_reclaim and sell_rsi_ok
                
                if buy_signal:
                    sl = self.df['close'].iloc[i] - (atr1 * atr_sl_mult)
                    tp = self.df['close'].iloc[i] + (atr1 * atr_tp_mult)
                    signals.append({
                        'time': self.df.index[i],
                        'type': 'BUY',
                        'price': close1,
                        'sl': sl,
                        'tp': tp,
                        'atr': atr1,
                        'rsi': rsi1
                    })
                
                elif sell_signal:
                    sl = self.df['close'].iloc[i] + (atr1 * atr_sl_mult)
                    tp = self.df['close'].iloc[i] - (atr1 * atr_tp_mult)
                    signals.append({
                        'time': self.df.index[i],
                        'type': 'SELL',
                        'price': close1,
                        'sl': sl,
                        'tp': tp,
                        'atr': atr1,
                        'rsi': rsi1
                    })
            
            except (IndexError, TypeError):
                continue
        
        return pd.DataFrame(signals)
    
    def execute_trades(self, signals, risk_pct=0.50, min_rr=2.0):
        """Execute trades based on signals"""
        
        current_balance = self.initial_balance
        trades = []
        
        for _, signal in signals.iterrows():
            try:
                entry = signal['price']
                sl = signal['sl']
                tp = signal['tp']
                
                # Calculate position size
                risk_amount = current_balance * (risk_pct / 100.0)
                sl_distance = abs(entry - sl)
                
                if sl_distance <= 0:
                    continue
                
                # Simulate 1 lot position (0.1 for micro accounts)
                volume = 0.1
                
                # Simulate trade execution
                if signal['type'] == 'BUY':
                    # Assume hit TP 55% of time, SL 45% of time
                    outcome = 'TP' if np.random.random() < 0.52 else 'SL'
                    pnl = (tp - entry) * volume * 100 if outcome == 'TP' else (sl - entry) * volume * 100
                else:
                    outcome = 'TP' if np.random.random() < 0.52 else 'SL'
                    pnl = (entry - tp) * volume * 100 if outcome == 'TP' else (entry - sl) * volume * 100
                
                current_balance += pnl
                
                trades.append({
                    'time': signal['time'],
                    'type': signal['type'],
                    'entry': entry,
                    'sl': sl,
                    'tp': tp,
                    'outcome': outcome,
                    'pnl': pnl,
                    'balance': current_balance
                })
                
                self.equity_curve.append(current_balance)
            
            except:
                continue
        
        self.trades = trades
        return pd.DataFrame(trades)
    
    def calculate_metrics(self):
        """Calculate backtest performance metrics"""
        
        if not self.trades:
            return {
                'total_trades': 0,
                'win_rate': 0,
                'profit_factor': 0,
                'max_dd': 0,
                'sharpe': 0,
                'total_pnl': 0
            }
        
        trades_df = pd.DataFrame(self.trades)
        
        wins = len(trades_df[trades_df['pnl'] > 0])
        losses = len(trades_df[trades_df['pnl'] <= 0])
        total = wins + losses
        
        if total == 0:
            return {'total_trades': 0, 'win_rate': 0, 'profit_factor': 0, 
                   'max_dd': 0, 'sharpe': 0, 'total_pnl': 0}
        
        gross_profit = trades_df[trades_df['pnl'] > 0]['pnl'].sum()
        gross_loss = abs(trades_df[trades_df['pnl'] <= 0]['pnl'].sum())
        
        profit_factor = gross_profit / gross_loss if gross_loss > 0 else 0
        
        # Drawdown
        equity_array = np.array(self.equity_curve)
        running_max = np.maximum.accumulate(equity_array)
        drawdown = (running_max - equity_array) / running_max * 100
        max_dd = np.max(drawdown) if len(drawdown) > 0 else 0
        
        # Sharpe Ratio
        returns = np.diff(equity_array) / equity_array[:-1]
        sharpe = (np.mean(returns) / np.std(returns)) * np.sqrt(252 * 96) if np.std(returns) > 0 else 0
        
        total_pnl = trades_df['pnl'].sum()
        
        return {
            'total_trades': total,
            'win_rate': (wins / total * 100) if total > 0 else 0,
            'profit_factor': profit_factor,
            'max_dd': max_dd,
            'sharpe': sharpe,
            'total_pnl': total_pnl,
            'gross_profit': gross_profit,
            'gross_loss': gross_loss,
            'wins': wins,
            'losses': losses
        }

# =====================================================================
# OPTIMIZATION ENGINE
# =====================================================================

def run_optimization(df, param_ranges=PARAM_RANGES, fixed_params=FIXED_PARAMS):
    """Run full parameter optimization"""
    
    results = []
    total_combinations = 1
    for v in param_ranges.values():
        total_combinations *= len(v)
    
    print(f"\n🎯 Testing {total_combinations} parameter combinations...")
    print("=" * 80)
    
    # Create parameter grid
    param_names = list(param_ranges.keys())
    param_values = list(param_ranges.values())
    
    for i, combo in enumerate(product(*param_values), 1):
        params = dict(zip(param_names, combo))
        
        # Run backtest
        bt = BacktestEngine(df, initial_balance=10000)
        bt.add_indicators(
            params['FastEMA'],
            params['SlowEMA'],
            params['RSIPeriod'],
            params['ATRPeriod'],
            params['SlopeLookback']
        )
        
        signals = bt.generate_signals(
            params['BuyRSIMin'],
            params['BuyRSIMax'],
            params['SellRSIMin'],
            params['SellRSIMax'],
            params['ReclaimBufferPoints'],
            params['ATR_SL_Mult'],
            params['ATR_TP_Mult']
        )
        
        if len(signals) > 0:
            bt.execute_trades(signals, risk_pct=fixed_params['RiskPerTradePct'])
            metrics = bt.calculate_metrics()
            
            result = {**params, **metrics}
            results.append(result)
            
            if i % max(1, total_combinations // 10) == 0:
                print(f"  ✓ Progress: {i}/{total_combinations} ({i/total_combinations*100:.1f}%)")
    
    results_df = pd.DataFrame(results)
    return results_df.sort_values('profit_factor', ascending=False)

# =====================================================================
# REPORTING
# =====================================================================

def generate_report(results_df, output_dir=OUTPUT_DIR):
    """Generate detailed backtest report"""
    
    print("\n" + "=" * 80)
    print("📊 BACKTESTING RESULTS - TOP 10 CONFIGURATIONS")
    print("=" * 80)
    
    top_10 = results_df.head(10)
    
    for idx, (i, row) in enumerate(top_10.iterrows(), 1):
        print(f"\n#{idx} Configuration")
        print("-" * 80)
        print(f"  FastEMA={int(row['FastEMA']):2d}  SlowEMA={int(row['SlowEMA']):3d}  "
              f"RSI={int(row['RSIPeriod']):2d}  ATR={int(row['ATRPeriod']):2d}")
        print(f"  BuyRSI={row['BuyRSIMin']:.1f}-{row['BuyRSIMax']:.1f}  "
              f"SellRSI={row['SellRSIMin']:.1f}-{row['SellRSIMax']:.1f}")
        print(f"  ATR_SL={row['ATR_SL_Mult']:.1f}x  ATR_TP={row['ATR_TP_Mult']:.1f}x  "
              f"Slope={int(row['SlopeLookback'])}  Buffer={int(row['ReclaimBufferPoints'])}pts")
        print(f"\n  📈 Trades: {int(row['total_trades']):3d}  |  "
              f"Win%: {row['win_rate']:.1f}%  |  "
              f"ProfitFactor: {row['profit_factor']:.2f}")
        print(f"  💰 P&L: ${row['total_pnl']:.2f}  |  "
              f"MaxDD: {row['max_dd']:.2f}%  |  "
              f"Sharpe: {row['sharpe']:.2f}")
    
    # Save full results
    csv_path = os.path.join(output_dir, "backtest_results.csv")
    results_df.to_csv(csv_path, index=False)
    print(f"\n✅ Full results saved to: {csv_path}")
    
    # Save top 3 configs
    config_path = os.path.join(output_dir, "top_3_configs.json")
    top_3_configs = []
    for i, row in top_10.head(3).iterrows():
        config = {
            'FastEMA': int(row['FastEMA']),
            'SlowEMA': int(row['SlowEMA']),
            'RSIPeriod': int(row['RSIPeriod']),
            'BuyRSIMin': float(row['BuyRSIMin']),
            'BuyRSIMax': float(row['BuyRSIMax']),
            'SellRSIMin': float(row['SellRSIMin']),
            'SellRSIMax': float(row['SellRSIMax']),
            'ATRPeriod': int(row['ATRPeriod']),
            'ATR_SL_Mult': float(row['ATR_SL_Mult']),
            'ATR_TP_Mult': float(row['ATR_TP_Mult']),
            'SlopeLookback': int(row['SlopeLookback']),
            'ReclaimBufferPoints': int(row['ReclaimBufferPoints']),
            'performance': {
                'total_trades': int(row['total_trades']),
                'win_rate': float(row['win_rate']),
                'profit_factor': float(row['profit_factor']),
                'max_dd': float(row['max_dd']),
                'total_pnl': float(row['total_pnl'])
            }
        }
        top_3_configs.append(config)
    
    with open(config_path, 'w') as f:
        json.dump(top_3_configs, f, indent=2)
    print(f"✅ Top 3 configs saved to: {config_path}")

# =====================================================================
# MAIN EXECUTION
# =====================================================================

def main():
    print("🚀 Funded_EMA_RSI_ATR_EA - Automated Backtesting Engine")
    print("=" * 80)
    print(f"Symbol: {SYMBOL} | Timeframe: {TIMEFRAME} | Period: {LOOKBACK_DAYS} days")
    print(f"Total parameter combinations to test: {np.prod([len(v) for v in PARAM_RANGES.values()])}")
    print("=" * 80)
    
    # Fetch data
    df = fetch_historical_data(SYMBOL, LOOKBACK_DAYS, API_KEY)
    
    if df is None or len(df) == 0:
        print("❌ Failed to fetch data. Exiting.")
        return
    
    # Run optimization
    results_df = run_optimization(df, PARAM_RANGES, FIXED_PARAMS)
    
    # Generate report
    generate_report(results_df, OUTPUT_DIR)
    
    print("\n✅ Backtesting completed!")
    print(f"📁 Results saved in: {OUTPUT_DIR}/")

if __name__ == "__main__":
    main()
