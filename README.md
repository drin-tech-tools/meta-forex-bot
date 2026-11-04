# EMA_Cross_Starter — MetaTrader 5 Expert Advisor

A single-file MQL5 EA: EMA 20/50 crossover on closed bars, ATR-based SL, fixed risk:reward TP,
%-of-equity position sizing, daily loss limit, spread and trading-hour filters, optional 200 EMA trend
filter, optional breakeven and ATR trailing stop.

> Educational starter. No strategy is guaranteed to be profitable. Demo-test before risking money.

## 1. Spec restated and assumptions

| Item | Behaviour |
|---|---|
| Symbol / TF | Trades the **chart symbol**; signal timeframe is an input (default H1). Works on any symbol/TF. |
| Entry | Buy when fast EMA(20) crosses above slow EMA(50) between bar 2 and bar 1 (both closed); sell on the opposite cross. Evaluated once per new bar. Bar 0 (forming) is never read. |
| Trend filter | Optional. Buy only if close[1] > EMA200[1]; sell only if close[1] < EMA200[1]. |
| SL / TP | SL = ATR(14)[1] × 1.5 from entry; TP = 2.0 × SL distance. All inputs. |
| Positions | Max one per symbol + magic. Opposite signal closes the open position (toggle) and then opens the new one if filters pass. |
| Lot size | `equity × risk% / ((SLdist / tickSize) × tickValue)`, rounded **down** to volume step, clamped to min/max. |
| Daily loss limit | Start-of-day equity is recorded at the first tick of each server day. If equity (incl. floating P/L) drops ≥ limit %, no new trades until the next server day. Closing and SL management still work. State is saved in terminal global variables so a restart does not reset it. |
| Spread / hours | Spread in **points** (10 points = 1 pip on 5-digit brokers). Hours use broker **server time**; start > end wraps past midnight. |
| Breakeven / trail | Breakeven at N·R (R = initial stop distance, read from the SL while it is still on the loss side). Trailing starts at N·R and trails ATR × multiplier behind price; the SL only ever moves in the favourable direction. |

Assumptions and deliberate choices:

1. **A signal that is filtered out is not retried** later in the same bar sequence; the next opportunity is the next cross. This avoids entering late and keeps behaviour identical in backtest and live.
2. **Risk-based volume below the broker minimum → trade skipped** (rather than forcing the min lot and over-risking). On small accounts raise the risk % or the account size.
3. For loss calculations the EA uses `SYMBOL_TRADE_TICK_VALUE_LOSS` and falls back to `SYMBOL_TRADE_TICK_VALUE` if the broker reports 0. For standard FX they are equal.
4. If the ATR-based SL/TP is closer than the broker's `STOPS_LEVEL` / `FREEZE_LEVEL`, the SL is widened to the minimum and the **lot size is calculated from the widened distance**, so risk % stays correct. TP is derived from the final SL distance.
5. The daily limit uses **equity**, so unrealised losses count.
6. On start-up the EA records the current bar and waits for the next new bar; it never trades on a cross that happened before it was attached.

## 2. Install and compile

1. In MT5: **File → Open Data Folder**.
2. Copy `EMA_Cross_Starter.mq5` into `MQL5/Experts/`.
3. Open **MetaEditor** (press **F4** in MT5), open the file, press **F7** to compile. The Toolbox → Errors tab should show `0 errors, 0 warnings`.
4. Back in MT5: Navigator (Ctrl+N) → Expert Advisors → right-click → Refresh.
5. Open an EURUSD chart, drag the EA onto it. On the **Common** tab tick *Allow Algo Trading*; on the **Inputs** tab review settings.
6. Make sure the toolbar **Algo Trading** button is green and there is a smiley face on the chart's top-right corner.

> The code was written and desk-checked without access to a MetaEditor install. If your build reports any warning on first compile, send me the line and I will fix it.

## 3. Backtest guide (Strategy Tester, Ctrl+R)

**Settings**

| Field | Value |
|---|---|
| Expert | EMA_Cross_Starter |
| Symbol / Period | EURUSD, H1 |
| Modeling | **Every tick based on real ticks** (needs the broker's tick history; the first run downloads it) |
| Deposit / Leverage | Your real account size and leverage, e.g. 10 000 USD, 1:30 |
| Delays | "Random delay" or ~100 ms to mimic latency |
| Optimization | Off for the first run |

**Suggested ranges.** Use 5 full years with at least one trending and one ranging year, e.g. 2020-01-01 → 2025-01-01.

**In-sample / out-of-sample split**

1. **In-sample (IS):** 2020-01-01 → 2023-01-01 — the only data the optimizer may see.
2. **Out-of-sample (OOS):** 2023-01-01 → 2025-01-01 — run **once**, after you have chosen parameters.
3. Optionally do **walk-forward**: Strategy Tester → Forward = "1/3" or a custom date. Optimize on IS, MT5 reports results on the forward part.
4. Accept the settings only if OOS profit factor, drawdown and trade count are roughly in line with IS (e.g. OOS PF ≥ ~70 % of IS PF). Big degradation = curve-fit.

**Avoiding curve-fitting with the optimizer**

- Optimize **few** parameters (EMA fast, EMA slow, ATR multiplier, RR at most). Never optimize hours, spread and magic together.
- Use coarse steps (e.g. fast 10–30 step 5; slow 40–100 step 10; ATR mult 1.0–3.0 step 0.5). Fine steps just find noise.
- Use the "Complex criterion" or Custom (e.g. profit factor / recovery factor), not raw net profit.
- Prefer a **plateau**: pick values whose neighbours are also profitable. An isolated spike is luck.
- Require ≥ 100–200 trades in IS; fewer is not statistically meaningful.
- Test the same settings on other symbols (GBPUSD, USDJPY, AUDUSD) and other timeframes (H4) as a robustness check.
- Stress test: double the spread, add slippage/delay, and shift the start date by a few months. If it collapses, it is not robust.
- Keep risk at 1 % while testing so drawdowns are realistic.

## 4. Demo forward-test checklist

- [ ] Compiles with 0 errors / 0 warnings on your MetaEditor build.
- [ ] Attached to a **demo** account with the same broker/server you plan to use live.
- [ ] Algo Trading button green; smiley face visible; Experts tab shows "EMA_Cross_Starter ready…".
- [ ] Inputs checked: magic number unique, risk %, daily loss %, spread, hours (in **server** time).
- [ ] First trade verified manually: lot size matches `equity × risk% ÷ SL money-per-lot`, SL/TP present and correct.
- [ ] Trades only on new bars, never mid-bar (check log timestamps).
- [ ] Trade skipped when spread is high / outside hours (Experts log lines "Skip: …").
- [ ] Opposite signal closes the position, and breakeven/trailing behave as intended if enabled.
- [ ] Daily loss limit tested (temporarily set to 0.1 %) and resets after midnight server time.
- [ ] Survives a terminal restart and a disconnect/reconnect without duplicate positions.
- [ ] Run **at least 4–8 weeks / 30+ trades** and compare with the backtest for the same period.
- [ ] Slippage and spread on demo broadly match the backtest assumptions.
- [ ] Go live with the smallest size (e.g. risk 0.25 %) for the first weeks, on a VPS, and only money you can afford to lose.

## 5. Ideas for v2

- **News filter:** use the MQL5 economic calendar (`CalendarValueHistory`) to block entries and optionally flatten N minutes around high-impact events.
- **Multi-symbol:** run one instance per symbol (distinct magic) or refactor to a symbol array with per-symbol handles, plus a portfolio-wide risk cap and currency-exposure check (avoid being long EURUSD and GBPUSD at 2 % each).
- **Partial closes:** close 50 % at 1R, move the rest to breakeven and trail (use `CTrade::PositionClosePartial`, respecting `SYMBOL_VOLUME_STEP`).
- Market-regime filter (ADX or ATR percentile) to avoid chop.
- Volatility-adjusted risk; weekly/monthly loss limits; max-consecutive-losses pause.
- Pending-order entries at the next bar's open; session-specific parameters.
- Equity-curve logging to CSV; Telegram/push notifications via `SendNotification`.
- Unit-style self test via `OnTester()` returning a custom criterion.
