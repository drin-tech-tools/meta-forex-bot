//+------------------------------------------------------------------+
//|                                             EMA_Cross_Starter.mq5 |
//|                         EMA crossover Expert Advisor for MT5      |
//+------------------------------------------------------------------+
//| STRATEGY IN ONE PARAGRAPH                                         |
//|   Once per new bar the EA looks at the two most recent CLOSED     |
//|   bars (shift 1 and shift 2). If the fast EMA crossed above the   |
//|   slow EMA it buys, if it crossed below it sells. The stop loss   |
//|   is ATR x multiplier away, the take profit is RR x the stop      |
//|   distance. Position size is calculated so that a stop-out loses  |
//|   only a fixed % of account equity.                               |
//|                                                                   |
//| IMPORTANT                                                         |
//|   This is an educational starter. No strategy is guaranteed to    |
//|   be profitable. Test on a demo account first.                    |
//+------------------------------------------------------------------+
#property copyright   "EMA_Cross_Starter"
#property version     "1.00"
#property description "EMA crossover EA with ATR stops, %-risk sizing, daily loss limit,"
#property description "spread/time filters, optional 200 EMA trend filter, breakeven and trailing."

//--- Standard Library helpers: CTrade sends orders, CPositionInfo reads positions,
//--- CSymbolInfo reads symbol quotes/properties.
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS (these appear in the EA "Inputs" tab and in the Tester)    |
//+------------------------------------------------------------------+
input group "=== Identification ==="
input ulong           InpMagic            = 20250101;     // Magic number (unique per EA/symbol; the EA only manages its own positions)
input string          InpComment          = "EMA_Cross_Starter"; // Order comment
input bool            InpVerbose          = true;         // Print extra info (skipped signals, filters) to the Experts log

input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_H1;    // Timeframe the signals are calculated on
input int             InpFastEMA          = 20;           // Fast EMA period
input int             InpSlowEMA          = 50;           // Slow EMA period (must be larger than fast)
input bool            InpUseTrendFilter   = false;        // Only trade in the direction of the trend EMA
input int             InpTrendEMA         = 200;          // Trend EMA period (used only if the filter is on)
input bool            InpCloseOnOpposite  = true;         // Close the open position when the opposite signal appears

input group "=== Stop loss / take profit ==="
input int             InpATRPeriod        = 14;           // ATR period
input double          InpATRMultiplier    = 1.5;          // Stop loss distance = ATR x this value
input double          InpRiskReward       = 2.0;          // Take profit distance = stop distance x this value

input group "=== Risk management ==="
input double          InpRiskPercent      = 1.0;          // % of account equity risked per trade
input double          InpDailyLossPercent = 3.0;          // Stop opening trades for the day if equity falls this % below start-of-day equity (0 = off)
input int             InpMaxSpreadPoints  = 30;           // Max allowed spread in POINTS (0 = off). 10 points = 1 pip on 5-digit brokers
input ulong           InpDeviationPoints  = 20;           // Max slippage (deviation) in points for market orders

input group "=== Trading hours (broker SERVER time) ==="
input bool            InpUseTimeFilter    = true;         // Enable the trading-hours filter
input int             InpStartHour        = 7;            // Start hour (0-23), inclusive
input int             InpEndHour          = 20;           // End hour (0-23), exclusive. If start > end the window wraps past midnight

input group "=== Breakeven & trailing ==="
input bool            InpUseBreakeven     = false;        // Move SL to entry once profit reaches BreakevenR x initial risk
input double          InpBreakevenR       = 1.0;          // Breakeven trigger in R (1R = initial stop distance)
input int             InpBreakevenOffset  = 10;           // Points added beyond entry when moving to breakeven (covers spread/commission)
input bool            InpUseTrailing      = false;        // Trail the SL behind price using ATR
input double          InpTrailStartR      = 1.0;          // Trailing starts when profit reaches this many R
input double          InpTrailATRMult     = 1.5;          // Trailing distance = ATR x this value
input int             InpTrailStepPoints  = 20;           // Only move the SL if it improves by at least this many points (avoids modify spam)

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                      |
//+------------------------------------------------------------------+
CTrade         g_trade;            // order sender
CPositionInfo  g_pos;              // position reader
CSymbolInfo    g_sym;              // symbol quote reader

string          g_symbol;          // symbol the EA trades (the chart symbol)
ENUM_TIMEFRAMES g_tf;              // timeframe actually used

int g_hFast  = INVALID_HANDLE;     // indicator handles (created in OnInit, released in OnDeinit)
int g_hSlow  = INVALID_HANDLE;
int g_hTrend = INVALID_HANDLE;
int g_hATR   = INVALID_HANDLE;

datetime g_lastBarTime   = 0;      // open time of the last bar we processed
bool     g_barInit       = false;  // false until the first bar time has been recorded
int      g_minBars       = 0;      // minimum history bars needed before we trust the indicators

datetime g_dayStart      = 0;      // 00:00 server time of the day being tracked
double   g_dayStartEq    = 0.0;    // account equity at the start of that day
bool     g_dayHalted     = false;  // true once the daily loss limit has been hit
string   g_gvPrefix      = "";     // prefix for terminal global variables that persist the daily state

datetime g_nextModifyOk  = 0;      // throttle for SL modifications after a failure

//+------------------------------------------------------------------+
//| Small helpers                                                     |
//+------------------------------------------------------------------+

//--- Print only when verbose mode is on.
void LogV(const string msg)
  {
   if(InpVerbose)
      Print(msg);
  }

//--- Print the result of a failed trade request in a readable way.
void LogTradeFailure(const string action)
  {
   PrintFormat("%s FAILED: retcode=%u (%s), last error=%d, symbol=%s",
               action,
               g_trade.ResultRetcode(),
               g_trade.ResultRetcodeDescription(),
               GetLastError(),
               g_symbol);
   ResetLastError();
  }

//--- Is this retcode a success?
bool RetcodeOK(const uint rc)
  {
   return(rc == TRADE_RETCODE_DONE ||
          rc == TRADE_RETCODE_DONE_PARTIAL ||
          rc == TRADE_RETCODE_PLACED);
  }

//--- Number of decimals needed to display a volume step (0.01 -> 2, 0.1 -> 1, 1 -> 0).
int VolumeDigits(const double step)
  {
   int    d = 0;
   double s = step;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-9)
     {
      s *= 10.0;
      d++;
     }
   return(d);
  }

//--- Round a price to the symbol's tick size and digits.
double NormalizePrice(const double price)
  {
   const double tick = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double p = price;
   if(tick > 0.0)
      p = MathRound(p / tick) * tick;
   return(NormalizeDouble(p, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));
  }

//--- Minimum allowed distance (in price units) between market price and SL/TP.
//--- Uses the larger of the broker's stops level and freeze level, plus 1 point of safety.
double MinStopDistance()
  {
   const double point  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   const long   stops  = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long   freeze = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const long   lvl    = (stops > freeze) ? stops : freeze;
   return((double)(lvl + 1) * point);
  }

//--- Copy `count` values of buffer 0 of an indicator starting at bar `start`.
//--- The array is "as series": out[0] is the NEWEST requested bar (shift = start).
bool ReadBuffer(const int handle, const int start, const int count, double &out[], const string name)
  {
   ArraySetAsSeries(out, true);
   if(BarsCalculated(handle) < start + count)
     {
      LogV(StringFormat("%s not ready yet (BarsCalculated=%d).", name, BarsCalculated(handle)));
      return(false);
     }
   const int copied = CopyBuffer(handle, 0, start, count, out);
   if(copied != count)
     {
      PrintFormat("CopyBuffer(%s) failed: copied=%d expected=%d error=%d", name, copied, count, GetLastError());
      ResetLastError();
      return(false);
     }
   for(int i = 0; i < count; i++)
     {
      if(out[i] == EMPTY_VALUE || !MathIsValidNumber(out[i]))
        {
         PrintFormat("Invalid value in %s buffer at index %d.", name, i);
         return(false);
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Daily loss limit                                                  |
//+------------------------------------------------------------------+

//--- Midnight (server time) of the given time.
datetime DayStartOf(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return(StructToTime(dt));
  }

//--- Save the daily state to terminal global variables so an EA restart mid-day
//--- does not reset the start-of-day equity or forget that the limit was hit.
void SaveDailyState()
  {
   GlobalVariableSet(g_gvPrefix + "DAY",  (double)g_dayStart);
   GlobalVariableSet(g_gvPrefix + "EQ",   g_dayStartEq);
   GlobalVariableSet(g_gvPrefix + "HALT", g_dayHalted ? 1.0 : 0.0);
  }

//--- Called every tick: rolls the day over, and latches the halt flag when the limit is breached.
void UpdateDailyState()
  {
   const datetime today = DayStartOf(TimeCurrent());
   if(today != g_dayStart)
     {
      // A new trading day (server time) has started: remember today's starting equity.
      g_dayStart   = today;
      g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayHalted  = false;
      SaveDailyState();
      LogV(StringFormat("New day %s. Start-of-day equity = %.2f", TimeToString(g_dayStart, TIME_DATE), g_dayStartEq));
     }

   if(InpDailyLossPercent > 0.0 && !g_dayHalted && g_dayStartEq > 0.0)
     {
      const double limitEq = g_dayStartEq * (1.0 - InpDailyLossPercent / 100.0);
      if(AccountInfoDouble(ACCOUNT_EQUITY) <= limitEq)
        {
         g_dayHalted = true;
         SaveDailyState();
         PrintFormat("DAILY LOSS LIMIT HIT: equity %.2f <= %.2f (%.2f%% below %.2f). No new trades until the next day.",
                     AccountInfoDouble(ACCOUNT_EQUITY), limitEq, InpDailyLossPercent, g_dayStartEq);
        }
     }
  }

//--- Restore the daily state in OnInit (live/demo only; the tester always starts fresh).
void InitDailyState()
  {
   g_gvPrefix = StringFormat("EMACS_%I64d_%I64u_%s_", AccountInfoInteger(ACCOUNT_LOGIN), InpMagic, g_symbol);

   if(MQLInfoInteger(MQL_TESTER))
     {
      // Make sure no stale value from a previous test run is picked up.
      GlobalVariableDel(g_gvPrefix + "DAY");
      GlobalVariableDel(g_gvPrefix + "EQ");
      GlobalVariableDel(g_gvPrefix + "HALT");
     }

   const datetime today = DayStartOf(TimeCurrent());
   if(GlobalVariableCheck(g_gvPrefix + "DAY") &&
      (datetime)(long)GlobalVariableGet(g_gvPrefix + "DAY") == today &&
      GlobalVariableGet(g_gvPrefix + "EQ") > 0.0)
     {
      g_dayStart   = today;
      g_dayStartEq = GlobalVariableGet(g_gvPrefix + "EQ");
      g_dayHalted  = (GlobalVariableGet(g_gvPrefix + "HALT") > 0.5);
      PrintFormat("Restored daily state: start-of-day equity %.2f, halted=%s", g_dayStartEq, g_dayHalted ? "yes" : "no");
     }
   else
     {
      g_dayStart = 0;      // forces UpdateDailyState() to start a new day record
      UpdateDailyState();
     }
  }

//+------------------------------------------------------------------+
//| Filters                                                           |
//+------------------------------------------------------------------+

//--- True if the terminal, account and symbol allow trading in the given direction.
bool TradingAllowed(const bool isBuy)
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     { LogV("Skip: Algo Trading is disabled in the terminal (toolbar button)."); return(false); }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { LogV("Skip: Algo Trading is not allowed for this EA (check the EA's Common tab)."); return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { LogV("Skip: trading is not allowed on this account."); return(false); }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     { LogV("Skip: the broker does not allow Expert Advisors on this account."); return(false); }

   const ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_FULL)
      return(true);
   if(mode == SYMBOL_TRADE_MODE_LONGONLY)
     {
      if(!isBuy) { LogV("Skip: symbol is long-only."); return(false); }
      return(true);
     }
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY)
     {
      if(isBuy) { LogV("Skip: symbol is short-only."); return(false); }
      return(true);
     }
   LogV("Skip: symbol trading is disabled or close-only (market closed?).");
   return(false);
  }

//--- Is the current server hour inside the allowed window?
bool InTradingHours()
  {
   if(!InpUseTimeFilter)
      return(true);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int h = dt.hour;
   if(InpStartHour == InpEndHour)
      return(true);                              // same start and end = whole day
   if(InpStartHour < InpEndHour)
      return(h >= InpStartHour && h < InpEndHour);
   return(h >= InpStartHour || h < InpEndHour);  // window wraps past midnight
  }

//--- Is the current spread acceptable?
bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return(false);
   const double spreadPts = (g_sym.Ask() - g_sym.Bid()) / point;
   if(spreadPts > (double)InpMaxSpreadPoints)
     {
      LogV(StringFormat("Skip: spread %.1f points > max %d.", spreadPts, InpMaxSpreadPoints));
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Position helpers (only positions with OUR symbol AND magic)       |
//+------------------------------------------------------------------+

//--- Is the position at the currently selected index ours?
bool IsOurPosition()
  {
   return(g_pos.Symbol() == g_symbol && (ulong)g_pos.Magic() == InpMagic);
  }

//--- Does the EA have any open position? If so, report the direction of the first one found.
bool HasOurPosition(ENUM_POSITION_TYPE &type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(!IsOurPosition())
         continue;
      type = g_pos.PositionType();
      return(true);
     }
   return(false);
  }

//--- Close every one of our positions of the given type. Returns true if none are left open.
bool CloseOurPositions(const ENUM_POSITION_TYPE type)
  {
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i))
         continue;
      if(!IsOurPosition() || g_pos.PositionType() != type)
         continue;

      const ulong ticket = g_pos.Ticket();
      if(g_trade.PositionClose(ticket, InpDeviationPoints) && RetcodeOK(g_trade.ResultRetcode()))
         PrintFormat("Closed position #%I64u on opposite signal.", ticket);
      else
        {
         LogTradeFailure(StringFormat("Close position #%I64u", ticket));
         allClosed = false;
        }
     }
   return(allClosed);
  }

//+------------------------------------------------------------------+
//| Position sizing                                                   |
//+------------------------------------------------------------------+

//--- Calculate the lot size so that hitting the SL loses InpRiskPercent of equity.
//---   loss per 1 lot = (SL distance / tick size) * tick value
//---   lots           = money at risk / loss per 1 lot
//--- Returns false if a valid, tradable volume cannot be produced.
bool CalculateLots(const double slDistance, double &lots)
  {
   lots = 0.0;
   if(slDistance <= 0.0)
     { Print("CalculateLots: invalid SL distance."); return(false); }

   const double tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue      = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);  // value of a tick when the trade LOSES
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);               // fall back to the plain tick value
   if(tickSize <= 0.0 || tickValue <= 0.0)
     { Print("CalculateLots: broker returned zero tick size/value."); return(false); }

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double riskMoney = equity * InpRiskPercent / 100.0;
   const double lossPerLot = (slDistance / tickSize) * tickValue;
   if(riskMoney <= 0.0 || lossPerLot <= 0.0)
     { Print("CalculateLots: invalid risk amount."); return(false); }

   double raw = riskMoney / lossPerLot;

   // Normalize to the broker's min / max / step.
   const double vMin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vMax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double       vStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vStep <= 0.0)
      vStep = (vMin > 0.0) ? vMin : 0.01;

   if(raw < vMin)
     {
      PrintFormat("Skip: risk-based volume %.4f is below the broker minimum %.4f (would risk more than %.2f%%).",
                  raw, vMin, InpRiskPercent);
      return(false);
     }
   if(raw > vMax)
      raw = vMax;

   // Round DOWN to the step so we never risk more than requested.
   raw = vMin + MathFloor((raw - vMin) / vStep + 1e-8) * vStep;
   raw = NormalizeDouble(raw, VolumeDigits(vStep));
   if(raw < vMin || raw > vMax + 1e-12)
     { Print("CalculateLots: normalized volume out of range."); return(false); }

   lots = raw;
   return(true);
  }

//+------------------------------------------------------------------+
//| Opening a trade                                                   |
//+------------------------------------------------------------------+
void OpenTrade(const bool isBuy, const double atr)
  {
   if(!g_sym.RefreshRates())
     { Print("OpenTrade: RefreshRates failed."); return; }

   const double ask = g_sym.Ask();
   const double bid = g_sym.Bid();
   if(ask <= 0.0 || bid <= 0.0)
     { Print("OpenTrade: no valid quote (market closed?)."); return; }

   const double entry   = isBuy ? ask : bid;
   const double minDist = MinStopDistance();

   // --- Stop loss: ATR x multiplier, never closer than the broker allows.
   double slDist = atr * InpATRMultiplier;
   double sl     = isBuy ? entry - slDist : entry + slDist;
   if(isBuy)
      sl = MathMin(sl, bid - minDist);     // for longs, stops are measured from the BID
   else
      sl = MathMax(sl, ask + minDist);     // for shorts, from the ASK
   sl = NormalizePrice(sl);
   if(sl <= 0.0)
     { Print("OpenTrade: computed SL is not a valid price."); return; }

   // The real stop distance (may be wider than ATR x mult if the broker's minimum forced it).
   slDist = MathAbs(entry - sl);

   // --- Take profit: RR x the stop distance, also respecting the minimum distance.
   double tp = isBuy ? entry + slDist * InpRiskReward : entry - slDist * InpRiskReward;
   if(isBuy)
      tp = MathMax(tp, bid + minDist);
   else
      tp = MathMin(tp, ask - minDist);
   tp = NormalizePrice(tp);
   if(tp <= 0.0)
     { Print("OpenTrade: computed TP is not a valid price."); return; }

   // --- Position size from the real stop distance.
   double lots = 0.0;
   if(!CalculateLots(slDist, lots))
      return;

   // --- Make sure we have enough free margin.
   double margin = 0.0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, g_symbol, lots, entry, margin))
     {
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
        {
         PrintFormat("Skip: required margin %.2f exceeds free margin %.2f for %.2f lots.",
                     margin, AccountInfoDouble(ACCOUNT_MARGIN_FREE), lots);
         return;
        }
     }
   else
      PrintFormat("Warning: OrderCalcMargin failed (error %d); continuing.", GetLastError());

   // --- Send the order (retry a few times on requotes / price changes).
   bool sent = false;
   for(int attempt = 1; attempt <= 3 && !sent; attempt++)
     {
      ResetLastError();
      bool ok;
      if(isBuy)
         ok = g_trade.Buy(lots, g_symbol, 0.0, sl, tp, InpComment);   // price 0 = current ask
      else
         ok = g_trade.Sell(lots, g_symbol, 0.0, sl, tp, InpComment);  // price 0 = current bid

      const uint rc = g_trade.ResultRetcode();
      if(ok && RetcodeOK(rc))
        {
         const int dg = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
         PrintFormat("%s %.2f lots %s at %s  SL=%s  TP=%s  (risk %.2f%%, ATR=%s)",
                     isBuy ? "BUY" : "SELL", lots, g_symbol,
                     DoubleToString(g_trade.ResultPrice(), dg),
                     DoubleToString(sl, dg), DoubleToString(tp, dg),
                     InpRiskPercent, DoubleToString(atr, dg));
         sent = true;
        }
      else
        {
         LogTradeFailure(StringFormat("%s attempt %d", isBuy ? "Buy" : "Sell", attempt));
         if(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF)
           {
            Sleep(200);
            g_sym.RefreshRates();
           }
         else
            break;   // other errors (invalid stops, no money, market closed...) will not fix themselves
        }
     }
  }

//+------------------------------------------------------------------+
//| Breakeven / trailing stop                                         |
//+------------------------------------------------------------------+

//--- Manage the SL of every open position that belongs to this EA.
void ManageOpenPositions()
  {
   if(!InpUseBreakeven && !InpUseTrailing)
      return;
   if(TimeCurrent() < g_nextModifyOk)
      return;

   // ATR is only needed for trailing. Read the last CLOSED bar's ATR.
   double atr = 0.0;
   if(InpUseTrailing)
     {
      double atrBuf[];
      if(!ReadBuffer(g_hATR, 1, 1, atrBuf, "ATR"))
         return;
      atr = atrBuf[0];
      if(atr <= 0.0)
         return;
     }

   if(!g_sym.RefreshRates())
      return;

   const double point   = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   const double minDist = MinStopDistance();
   const double freeze  = (double)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   const double step    = MathMax((double)InpTrailStepPoints * point, point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!g_pos.SelectByIndex(i) || !IsOurPosition())
         continue;

      const ulong  ticket = g_pos.Ticket();
      const bool   isBuy  = (g_pos.PositionType() == POSITION_TYPE_BUY);
      const double open   = g_pos.PriceOpen();
      const double curSL  = g_pos.StopLoss();
      const double curTP  = g_pos.TakeProfit();
      const double price  = isBuy ? g_sym.Bid() : g_sym.Ask();          // price at which the position would close
      const double profit = isBuy ? price - open : open - price;        // profit in price units
      if(profit <= 0.0)
         continue;

      // Respect the freeze level: the broker refuses changes when price is too near SL/TP.
      if(freeze > 0.0)
        {
         if(curTP > 0.0 && MathAbs(curTP - price) <= freeze) continue;
         if(curSL > 0.0 && MathAbs(curSL - price) <= freeze) continue;
        }

      double newSL = curSL;   // start from the current SL; candidates may only improve it

      // ---- Breakeven candidate -------------------------------------
      // 1R is derived from the CURRENT SL while it is still on the losing side of entry.
      // Once the SL has moved to/above entry this block is skipped automatically.
      if(InpUseBreakeven && curSL > 0.0)
        {
         const bool slOnLossSide = isBuy ? (curSL < open) : (curSL > open);
         if(slOnLossSide)
           {
            const double oneR = MathAbs(open - curSL);
            if(profit >= InpBreakevenR * oneR)
              {
               const double beSL = isBuy ? open + (double)InpBreakevenOffset * point
                                         : open - (double)InpBreakevenOffset * point;
               if(isBuy ? (beSL > newSL) : (newSL == 0.0 || beSL < newSL))
                  newSL = beSL;
              }
           }
        }

      // ---- ATR trailing candidate ----------------------------------
      if(InpUseTrailing)
        {
         const double oneRatr = atr * InpATRMultiplier;     // "1R" in ATR terms
         if(profit >= InpTrailStartR * oneRatr)
           {
            const double trailSL = isBuy ? price - atr * InpTrailATRMult
                                         : price + atr * InpTrailATRMult;
            if(isBuy ? (trailSL > newSL) : (newSL == 0.0 || trailSL < newSL))
               newSL = trailSL;
           }
        }

      newSL = NormalizePrice(newSL);

      // Only modify if the SL really improved by at least one step (or one tick for the first set).
      bool improved;
      if(curSL <= 0.0)
         improved = (newSL > 0.0);
      else
         improved = isBuy ? (newSL >= curSL + step) : (newSL <= curSL - step);
      if(!improved)
         continue;

      // The new SL must keep the minimum distance from the market and never cross the price.
      if(isBuy && newSL > price - minDist)
         continue;
      if(!isBuy && newSL < price + minDist)
         continue;

      if(g_trade.PositionModify(ticket, newSL, curTP) && RetcodeOK(g_trade.ResultRetcode()))
         LogV(StringFormat("Position #%I64u SL moved %s -> %s", ticket,
                           DoubleToString(curSL, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
                           DoubleToString(newSL, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS))));
      else
        {
         LogTradeFailure(StringFormat("Modify SL of #%I64u", ticket));
         g_nextModifyOk = TimeCurrent() + 10;   // wait 10 seconds before trying again
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| New-bar logic: signals and entries                                |
//+------------------------------------------------------------------+

//--- True exactly once when a new bar starts. The very first call only records the bar
//--- so the EA never trades on stale history at start-up.
bool IsNewBar()
  {
   const datetime t = iTime(g_symbol, g_tf, 0);
   if(t == 0)
      return(false);                 // no history available yet
   if(!g_barInit)
     {
      g_barInit     = true;
      g_lastBarTime = t;
      return(false);
     }
   if(t != g_lastBarTime)
     {
      g_lastBarTime = t;
      return(true);
     }
   return(false);
  }

//--- Evaluate the crossover on closed bars and act on it.
void ProcessNewBar()
  {
   // Enough history? (also covers "no history" after weekends or on fresh symbols)
   if(Bars(g_symbol, g_tf) < g_minBars)
     {
      LogV(StringFormat("Skip: only %d bars available, need %d.", Bars(g_symbol, g_tf), g_minBars));
      return;
     }

   // Indicator values: index 0 = bar 1 (last CLOSED bar), index 1 = bar 2. Bar 0 (forming) is never used.
   double fast[], slow[], atrBuf[], trend[];
   if(!ReadBuffer(g_hFast, 1, 2, fast, "FastEMA"))   return;
   if(!ReadBuffer(g_hSlow, 1, 2, slow, "SlowEMA"))   return;
   if(!ReadBuffer(g_hATR,  1, 1, atrBuf, "ATR"))     return;
   const double atr = atrBuf[0];
   if(atr <= 0.0)
     { LogV("Skip: ATR is zero."); return; }

   // --- Crossover detection --------------------------------------------------
   int signal = 0;                                            // +1 buy, -1 sell, 0 none
   if(fast[1] <= slow[1] && fast[0] > slow[0])
      signal = 1;                                             // fast crossed ABOVE slow
   else if(fast[1] >= slow[1] && fast[0] < slow[0])
      signal = -1;                                            // fast crossed BELOW slow
   if(signal == 0)
      return;

   const bool isBuy = (signal > 0);
   PrintFormat("%s signal on closed bar %s (fast %.5f / slow %.5f)",
               isBuy ? "BUY" : "SELL", TimeToString(iTime(g_symbol, g_tf, 1)), fast[0], slow[0]);

   // --- Existing position handling ---------------------------------------------
   ENUM_POSITION_TYPE existing = POSITION_TYPE_BUY;
   if(HasOurPosition(existing))
     {
      const bool existingIsBuy = (existing == POSITION_TYPE_BUY);
      if(existingIsBuy == isBuy)
        { LogV("Skip: already in a position in this direction."); return; }

      if(!InpCloseOnOpposite)
        { LogV("Skip: opposite position open and close-on-opposite is off."); return; }

      if(!CloseOurPositions(existing))
         return;                         // could not close; do not open a new one
     }

   // --- Entry filters ---------------------------------------------------------------
   if(g_dayHalted)
     { LogV("Skip: daily loss limit reached."); return; }
   if(!TradingAllowed(isBuy))
      return;
   if(!InTradingHours())
     { LogV("Skip: outside trading hours."); return; }
   if(!g_sym.RefreshRates())
     { Print("Skip: RefreshRates failed."); return; }
   if(!SpreadOK())
      return;

   if(InpUseTrendFilter)
     {
      if(!ReadBuffer(g_hTrend, 1, 1, trend, "TrendEMA"))
         return;
      const double close1 = iClose(g_symbol, g_tf, 1);
      if(close1 <= 0.0)
         return;
      if((isBuy && close1 <= trend[0]) || (!isBuy && close1 >= trend[0]))
        { LogV("Skip: signal is against the trend EMA."); return; }
     }

   // Safety: another position may still be open if closing partially failed.
   ENUM_POSITION_TYPE leftover = POSITION_TYPE_BUY;
   if(HasOurPosition(leftover))
      return;

   OpenTrade(isBuy, atr);
  }

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 1. Validate inputs
   if(InpFastEMA < 1 || InpSlowEMA < 2 || InpFastEMA >= InpSlowEMA)
     { Print("Invalid inputs: need 1 <= FastEMA < SlowEMA."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpUseTrendFilter && InpTrendEMA < 2)
     { Print("Invalid inputs: TrendEMA must be >= 2."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpATRPeriod < 1 || InpATRMultiplier <= 0.0 || InpRiskReward <= 0.0)
     { Print("Invalid inputs: ATR period, ATR multiplier and risk:reward must be positive."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 10.0)
     { Print("Invalid inputs: RiskPercent must be in (0, 10]."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpDailyLossPercent < 0.0 || InpDailyLossPercent >= 100.0)
     { Print("Invalid inputs: DailyLossPercent must be in [0, 100)."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
     { Print("Invalid inputs: trading hours must be 0-23."); return(INIT_PARAMETERS_INCORRECT); }
   if(InpBreakevenR <= 0.0 || InpTrailStartR <= 0.0 || InpTrailATRMult <= 0.0 ||
      InpBreakevenOffset < 0 || InpTrailStepPoints < 0)
     { Print("Invalid inputs: breakeven/trailing values must be positive."); return(INIT_PARAMETERS_INCORRECT); }

   //--- 2. Symbol and timeframe
   g_symbol = _Symbol;
   g_tf     = (InpTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpTimeframe;

   if(!g_sym.Name(g_symbol))
     { PrintFormat("Cannot select symbol %s.", g_symbol); return(INIT_FAILED); }
   if(!SymbolSelect(g_symbol, true))
      PrintFormat("Warning: SymbolSelect(%s) failed.", g_symbol);

   //--- 3. Indicator handles (EMA on close price, ATR)
   g_hFast = iMA(g_symbol, g_tf, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE)
     { PrintFormat("iMA(fast) failed, error %d", GetLastError()); return(INIT_FAILED); }

   g_hSlow = iMA(g_symbol, g_tf, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hSlow == INVALID_HANDLE)
     { PrintFormat("iMA(slow) failed, error %d", GetLastError()); return(INIT_FAILED); }

   if(InpUseTrendFilter)
     {
      g_hTrend = iMA(g_symbol, g_tf, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hTrend == INVALID_HANDLE)
        { PrintFormat("iMA(trend) failed, error %d", GetLastError()); return(INIT_FAILED); }
     }

   g_hATR = iATR(g_symbol, g_tf, InpATRPeriod);
   if(g_hATR == INVALID_HANDLE)
     { PrintFormat("iATR failed, error %d", GetLastError()); return(INIT_FAILED); }

   //--- 4. History needed before the indicators are trustworthy
   int longest = MathMax(InpSlowEMA, InpATRPeriod);
   if(InpUseTrendFilter)
      longest = MathMax(longest, InpTrendEMA);
   g_minBars = longest * 3 + 10;     // EMAs need extra bars to "settle"

   //--- 5. Trade object configuration
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetAsyncMode(false);                       // wait for the server reply so we can check retcodes
   if(!g_trade.SetTypeFillingBySymbol(g_symbol))      // detect FOK / IOC / RETURN supported by the symbol
      Print("Warning: SetTypeFillingBySymbol failed; using the default filling mode.");

   //--- 6. Daily loss tracking
   InitDailyState();

   PrintFormat("EMA_Cross_Starter ready: %s %s | EMA %d/%d | ATR(%d) x %.2f | RR %.2f | risk %.2f%% | magic %I64u",
               g_symbol, EnumToString(g_tf), InpFastEMA, InpSlowEMA, InpATRPeriod,
               InpATRMultiplier, InpRiskReward, InpRiskPercent, InpMagic);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles so the terminal can free the memory.
   if(g_hFast  != INVALID_HANDLE) { IndicatorRelease(g_hFast);  g_hFast  = INVALID_HANDLE; }
   if(g_hSlow  != INVALID_HANDLE) { IndicatorRelease(g_hSlow);  g_hSlow  = INVALID_HANDLE; }
   if(g_hTrend != INVALID_HANDLE) { IndicatorRelease(g_hTrend); g_hTrend = INVALID_HANDLE; }
   if(g_hATR   != INVALID_HANDLE) { IndicatorRelease(g_hATR);   g_hATR   = INVALID_HANDLE; }
  }

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Every tick: keep the daily-loss tracker current and manage SL for open trades.
   UpdateDailyState();
   ManageOpenPositions();

   // Signals are evaluated ONCE per new bar, on closed bars only.
   if(!IsNewBar())
      return;
   ProcessNewBar();
  }
//+------------------------------------------------------------------+
