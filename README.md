# MetaTrader 5 EA Template

A production-shaped starting point for MQL5 Expert Advisors.

**The strategy in this template has no edge, and that is deliberate.** It is an EMA crossover — the most published, most arbitraged entry rule in existence. It is here so the file compiles and runs.

What this repository is actually about is the infrastructure around the strategy: the parts that determine whether an EA survives contact with a live account, and the parts that are almost always missing from example code.

Swap out `EvaluateSignal()` for your own logic. Leave everything else.

A [cTrader version of the same template](https://github.com/Nico0100-algo/ctrader-bot-template) is also available.

---

## What it demonstrates

### 1. Bar-close evaluation

`OnTick()` fires constantly, so the EA compares `iTime(_Symbol, PERIOD_CURRENT, 0)` against the last stored bar time and only evaluates when a new bar opens. Signals read indices `1` and `2` — completed bars. Index `0` is still forming, and using it means acting on information that did not exist at the time.

This is the most common cause of backtest results that cannot be reproduced live.

### 2. Risk-based position sizing

Lots are derived from account balance, a risk percentage, and the actual stop distance:

```
lossPerLot = (stopDistance / tickSize) × tickValue
lots       = (balance × risk%) / lossPerLot
```

Never a fixed lot size. Volatility changes, account size changes, and fixed lots mean your real risk per trade drifts constantly without you noticing.

The result is rounded **down** to the broker's `SYMBOL_VOLUME_STEP` so the risk budget is never exceeded, then checked against `SYMBOL_VOLUME_MIN` and `SYMBOL_VOLUME_MAX`. A trade below the minimum is rejected with a log line explaining why, rather than silently sized up.

### 3. Protective stops that are verified, not assumed

Two things most examples get wrong:

**The stop is recalculated from the actual fill price**, not the pre-order estimate. Slippage between the two is real, and sizing a stop off the estimate means your risk is not what you think it is.

**The stop is confirmed, and retried if it fails.** `PositionModify` can be rejected — during session gaps, at market reopen, in fast conditions, or against broker stop-level restrictions. If it fails, the EA sets a flag and `OnTimer` retries every N seconds until the stop is attached. A filled position with no stop on it is the single most expensive bug in automated trading, and it happens quietly.

### 4. Restart recovery

If the EA is restarted or reattached while a position is open, `OnTimer` detects a position with `StopLoss() == 0` and reconstructs one from current ATR. Without this, a restart mid-trade leaves an unprotected position indefinitely.

### 5. Magic-number scoping

Every position is opened with a magic number and retrieved by filtering on both magic and symbol. The EA will never modify or close a position it did not open — whether that belongs to you, or to another EA running on the same account.

MQL5 has no position labels, so this is the only mechanism available. If you run several EAs on one account, it is not optional.

### 6. Logging that is actually useful

Every decision produces a line, including the ones where nothing happened:

```
STARTED | EURUSD PERIOD_H1 | Risk 1.00% | Stop 2.0xATR | Balance 10000.00
ENTRY | Sell EURUSD @ 1.15389 | 0.51 lots | ATR 0.00129 | stop 1.15647
PROTECTED | ticket 2 | SL 1.15647 | TP 1.14873
TRAIL | ticket 4 | SL 1.13801 -> 1.13847
EXIT | ticket 2 | reason TakeProfit | close 1.14873 | net 197.12 | balance 10195.97
REJECTED | calculated lot size below minimum — no trade
PROTECTION FAILED | ticket 5 | retcode 10018 (Market is closed) | will retry every 15s
```

Note that `EXIT` logs the **position ticket**, not the deal id, so every exit can be matched back to its `ENTRY` and `PROTECTED` lines. MQL5 numbers deals and positions separately, and logging the deal id — as most examples do — makes a log you cannot audit.

Rejections matter more than fills when you are diagnosing why live behaviour diverged from a backtest.

### 7. Configuration validation

Impossible parameter combinations are caught in `OnInit` and the EA returns `INIT_PARAMETERS_INCORRECT` with an explanatory message, rather than loading and producing nothing while you wonder why.

---

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| FastPeriod | 20 | Must be shorter than SlowPeriod |
| SlowPeriod | 50 | |
| AtrPeriod | 14 | Drives both stop distance and sizing |
| StopAtrMultiple | 2.0 | Volatility-scaled, not fixed points |
| TargetAtrMultiple | 4.0 | Set to 0 to disable take profit |
| RiskPercent | 1.0 | Percentage of balance at risk if the stop is hit |
| UseTrailingStop | true | Trails at the same ATR multiple, favourable direction only |
| MagicNumber | 20260915 | Change this if running multiple instances |
| RetrySeconds | 15 | Retry interval for rejected stop attachment |
| SlippagePoints | 10 | Max deviation on market orders |

---

## Installation

1. Open MetaEditor (F4 from MetaTrader 5)
2. **File → New → Expert Advisor**, then replace the contents with `EATemplate.mq5`
3. Compile (F7)
4. Attach to a chart, set parameters, run on **demo** first

---

## Backtesting note

Set Modelling to **Every tick based on real ticks**, not the default "Every tick". The default generates synthetic ticks from M1 bars — it is an approximation, not history.

The difference is not cosmetic. A strategy I tested on bar data returned over 28,000%. The same strategy on real tick data returned −9%. The gap was entirely down to intrabar fill assumptions the bar data could not see.

Bar-data backtests are a screening tool at best. They are not evidence.

Note also that real tick history is only available as far back as your broker stores it — often only a few months on a fresh demo account. Check the Journal for the `ticks data begins from` line before trusting a long backtest.

---

## Differences from the cTrader version

The two templates implement the same logic, but they will not produce identical results on the same symbol and period:

- **ATR smoothing differs.** MQL5's `iATR` applies its own smoothing; the cTrader version uses an exponential ATR. On the same bar these gave 0.00129 and 0.00156 respectively, which changes every stop distance and therefore every position size.
- **Server time differs** between brokers and platforms, so bars cover different windows. On H1 this is minor; on D1 it means genuinely different bars.
- **Position identity differs.** cTrader uses string labels; MQL5 uses magic numbers.

Neither is more correct. If a strategy's edge depends on which of these it runs under, that is worth knowing.

---

## Known limitations

- Single position per symbol per instance by design
- No news or economic calendar awareness
- No spread filter — worth adding for lower-timeframe work
- Trailing stop moves on bar close only, not intrabar
- Sizing assumes the symbol reports `SYMBOL_TRADE_TICK_VALUE` and `SYMBOL_TRADE_TICK_SIZE` correctly; verify on exotic instruments and CFDs
- Broker stop-level restrictions (`SYMBOL_TRADE_STOPS_LEVEL`) are not checked before placing stops — the retry path handles rejection, but a filter would be better
- Netting vs hedging account modes are not distinguished; tested on hedging
- The retry path for rejected stop attachment did not fire during testing — the Strategy Tester does not simulate broker rejections, so that branch is unproven in practice

---

## Licence

MIT. Use it, modify it, ship it.

---

Built by a developer who runs automated strategies on live capital. If you want a strategy implemented or independently tested before you automate it, get in touch.
