//+------------------------------------------------------------------+
//|                                                  EATemplate.mq5  |
//|            Production EA template for MetaTrader 5               |
//+------------------------------------------------------------------+
//
// The strategy here (EMA cross, ATR stop) is a PLACEHOLDER and has no edge.
// The point of this file is the infrastructure around it:
//
//   1. Bar-close evaluation, not tick-by-tick
//   2. Position sizing derived from risk % and stop distance
//   3. Hard protective stops verified after fill, with retry
//   4. Timer-based recovery for rejected modifications
//   5. Magic-number scoping so the EA only touches its own positions
//   6. Structured logging of every decision, including rejections
//
// Replace EvaluateSignal() with your own logic. Everything else stays.
//
//+------------------------------------------------------------------+

#property copyright "MIT Licence"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Strategy
input int    FastPeriod        = 20;     // Fast EMA
input int    SlowPeriod        = 50;     // Slow EMA

//--- Risk
input int    AtrPeriod         = 14;     // ATR period
input double StopAtrMultiple   = 2.0;    // Stop loss (ATR multiple)
input double TargetAtrMultiple = 4.0;    // Take profit (ATR multiple, 0 = off)
input double RiskPercent       = 1.0;    // Risk per trade (%)
input bool   UseTrailingStop   = true;   // Trail stop

//--- Operations
input ulong  MagicNumber       = 20260915; // Magic number (identifies our trades)
input int    RetrySeconds      = 15;       // Stop verify retry interval
input int    SlippagePoints    = 10;       // Max deviation in points

//--- Handles and objects
CTrade        trade;
CPositionInfo posInfo;

int    _fastHandle = INVALID_HANDLE;
int    _slowHandle = INVALID_HANDLE;
int    _atrHandle  = INVALID_HANDLE;

datetime _lastBarTime  = 0;
double   _pendingStop  = 0.0;
double   _pendingTarget= 0.0;
bool     _awaitingProtection = false;

//+------------------------------------------------------------------+
//| Initialisation                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(FastPeriod >= SlowPeriod)
   {
      Print("CONFIG ERROR: Fast EMA (", FastPeriod,
            ") must be shorter than Slow EMA (", SlowPeriod, "). Stopping.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   _fastHandle = iMA(_Symbol, PERIOD_CURRENT, FastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   _slowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   _atrHandle  = iATR(_Symbol, PERIOD_CURRENT, AtrPeriod);

   if(_fastHandle == INVALID_HANDLE || _slowHandle == INVALID_HANDLE || _atrHandle == INVALID_HANDLE)
   {
      Print("INIT FAILED: could not create indicator handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   // Recovery timer: re-attempts protective stops that were rejected at fill time.
   EventSetTimer(RetrySeconds);

   PrintFormat("STARTED | %s %s | Risk %.2f%% | Stop %.1fxATR | Balance %.2f",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)Period()),
               RiskPercent, StopAtrMultiple, AccountInfoDouble(ACCOUNT_BALANCE));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Shutdown                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   if(_fastHandle != INVALID_HANDLE) IndicatorRelease(_fastHandle);
   if(_slowHandle != INVALID_HANDLE) IndicatorRelease(_slowHandle);
   if(_atrHandle  != INVALID_HANDLE) IndicatorRelease(_atrHandle);

   Print("STOPPED | open positions left untouched");
}

//+------------------------------------------------------------------+
//| Tick handler — only used to detect a new bar and to trail         |
//+------------------------------------------------------------------+
void OnTick()
{
   // Entries are evaluated on bar close only. Tick-level entry logic is the
   // most common cause of backtest results that cannot be reproduced live.
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == _lastBarTime)
      return;

   _lastBarTime = currentBar;
   OnBarClosed();
}

//+------------------------------------------------------------------+
//| Runs once per completed bar                                       |
//+------------------------------------------------------------------+
void OnBarClosed()
{
   int required = MathMax(SlowPeriod, AtrPeriod) + 3;
   if(Bars(_Symbol, PERIOD_CURRENT) < required)
      return;

   if(SelectOurPosition())
   {
      ManageOpenPosition();
      return;
   }

   int signal = EvaluateSignal();
   if(signal != 0)
      OpenPosition(signal);
}

//+------------------------------------------------------------------+
//| PLACEHOLDER STRATEGY. Replace with your own rules.                |
//| Returns 1 for buy, -1 for sell, 0 for no trade.                   |
//+------------------------------------------------------------------+
int EvaluateSignal()
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   // Copy the last 3 values so we can read bars 1 and 2 (bar 0 is still forming)
   if(CopyBuffer(_fastHandle, 0, 0, 3, fast) < 3) return(0);
   if(CopyBuffer(_slowHandle, 0, 0, 3, slow) < 3) return(0);

   bool crossedUp   = (fast[2] <= slow[2] && fast[1] >  slow[1]);
   bool crossedDown = (fast[2] >= slow[2] && fast[1] <  slow[1]);

   if(crossedUp)   return(1);
   if(crossedDown) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
//| Open a position with risk-derived size and a protective stop      |
//+------------------------------------------------------------------+
void OpenPosition(int direction)
{
   double atr = GetAtr();
   if(atr <= 0)
   {
      PrintFormat("REJECTED | invalid ATR (%.5f) — no trade", atr);
      return;
   }

   double stopDistance = atr * StopAtrMultiple;
   double lots = CalculateLots(stopDistance);

   if(lots <= 0)
   {
      Print("REJECTED | calculated lot size below minimum — no trade");
      return;
   }

   double digits = (double)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool   isBuy  = (direction > 0);
   double price  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                         : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool sent = isBuy ? trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "EATemplate")
                     : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "EATemplate");

   if(!sent || trade.ResultRetcode() != TRADE_RETCODE_DONE)
   {
      PrintFormat("ENTRY FAILED | %s %.2f lots | retcode %d (%s)",
                  isBuy ? "Buy" : "Sell", lots,
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      _awaitingProtection = false;
      return;
   }

   if(!SelectOurPosition())
   {
      Print("ENTRY | order filled but position not found — will retry protection on timer");
      _awaitingProtection = true;
      return;
   }

   // Recompute protection from the ACTUAL fill, not the estimate. Slippage matters.
   double entry = posInfo.PriceOpen();

   _pendingStop = isBuy ? entry - stopDistance : entry + stopDistance;

   _pendingTarget = 0.0;
   if(TargetAtrMultiple > 0)
      _pendingTarget = isBuy ? entry + atr * TargetAtrMultiple
                             : entry - atr * TargetAtrMultiple;

   _pendingStop   = NormalizeDouble(_pendingStop,   (int)digits);
   _pendingTarget = NormalizeDouble(_pendingTarget, (int)digits);

   PrintFormat("ENTRY | %s %s @ %.5f | %.2f lots | ATR %.5f | stop %.5f",
               isBuy ? "Buy" : "Sell", _Symbol, entry, lots, atr, _pendingStop);

   ApplyProtection();
}

//+------------------------------------------------------------------+
//| Lot size from account risk and stop distance.                     |
//| Never a fixed lot size — risk stays constant as volatility and    |
//| account size change.                                              |
//+------------------------------------------------------------------+
double CalculateLots(double stopDistancePrice)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || stopDistancePrice <= 0)
   {
      Print("REJECTED | tick value or tick size unavailable for ", _Symbol);
      return(0.0);
   }

   // Money lost per 1.0 lot if the stop is hit
   double lossPerLot = (stopDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return(0.0);

   double lots = riskAmount / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Round DOWN to the broker's lot step so we never exceed the risk budget
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, 2);

   if(lots < minLot)
   {
      PrintFormat("SIZING | required %.4f lots is below symbol minimum %.2f",
                  riskAmount / lossPerLot, minLot);
      return(0.0);
   }

   if(lots > maxLot)
      lots = maxLot;

   return(lots);
}

//+------------------------------------------------------------------+
//| Attach the protective stop. If the broker rejects it, the flag    |
//| stays set and the timer retries until it sticks. A position       |
//| without a stop is the most expensive bug in automated trading.    |
//+------------------------------------------------------------------+
void ApplyProtection()
{
   if(!SelectOurPosition())
      return;

   ulong ticket = posInfo.Ticket();

   if(trade.PositionModify(ticket, _pendingStop, _pendingTarget))
   {
      _awaitingProtection = false;
      PrintFormat("PROTECTED | ticket %I64u | SL %.5f | TP %s",
                  ticket, _pendingStop,
                  _pendingTarget > 0 ? DoubleToString(_pendingTarget, 5) : "none");
   }
   else
   {
      _awaitingProtection = true;
      PrintFormat("PROTECTION FAILED | ticket %I64u | retcode %d (%s) | will retry every %ds",
                  ticket, trade.ResultRetcode(),
                  trade.ResultRetcodeDescription(), RetrySeconds);
   }
}

//+------------------------------------------------------------------+
//| Retry loop. Also catches a position with no stop at all — for     |
//| instance after the EA restarts mid-trade.                         |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!SelectOurPosition())
   {
      _awaitingProtection = false;
      return;
   }

   bool hasNoStop = (posInfo.StopLoss() == 0.0);

   if(_awaitingProtection || hasNoStop)
   {
      if(hasNoStop && !_awaitingProtection)
      {
         // Restart recovery: rebuild a stop from current ATR
         double atr = GetAtr();
         if(atr <= 0) return;

         double digits = (double)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         bool   isBuy  = (posInfo.PositionType() == POSITION_TYPE_BUY);

         _pendingStop = isBuy ? posInfo.PriceOpen() - atr * StopAtrMultiple
                              : posInfo.PriceOpen() + atr * StopAtrMultiple;
         _pendingStop = NormalizeDouble(_pendingStop, (int)digits);
         _pendingTarget = posInfo.TakeProfit();

         PrintFormat("RECOVERY | ticket %I64u found without stop — reconstructing at %.5f",
                     posInfo.Ticket(), _pendingStop);
      }

      ApplyProtection();
   }
}

//+------------------------------------------------------------------+
//| Trail the stop — favourable direction only                        |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!UseTrailingStop) return;
   if(posInfo.StopLoss() == 0.0) return;

   double atr = GetAtr();
   if(atr <= 0) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double digits = (double)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool   isBuy  = (posInfo.PositionType() == POSITION_TYPE_BUY);

   double candidate = isBuy ? close1 - atr * StopAtrMultiple
                            : close1 + atr * StopAtrMultiple;
   candidate = NormalizeDouble(candidate, (int)digits);

   // Stops only ever move in the favourable direction
   bool shouldMove = isBuy ? (candidate > posInfo.StopLoss())
                           : (candidate < posInfo.StopLoss());
   if(!shouldMove) return;

   // Capture before modifying — the log must show the real transition
   double previousStop = posInfo.StopLoss();
   ulong  ticket       = posInfo.Ticket();

   if(trade.PositionModify(ticket, candidate, posInfo.TakeProfit()))
      PrintFormat("TRAIL | ticket %I64u | SL %.5f -> %.5f", ticket, previousStop, candidate);
   else
      PrintFormat("TRAIL FAILED | ticket %I64u | retcode %d (%s)",
                  ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Log every exit. Without this the log shows entries but no closes, |
//| and a trade cannot be reconstructed from it.                      |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest    &request,
                        const MqlTradeResult     &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber)
      return;

   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   string reason = DealCloseReason(trans.deal);

   _awaitingProtection = false;

   // Log the POSITION ticket, not the deal id, so this line can be matched
   // back to its ENTRY and PROTECTED lines.
   PrintFormat("EXIT | ticket %I64u | reason %s | close %.5f | net %.2f | balance %.2f",
               trans.position, reason,
               HistoryDealGetDouble(trans.deal, DEAL_PRICE),
               profit, AccountInfoDouble(ACCOUNT_BALANCE));
}

//+------------------------------------------------------------------+
//| Helpers                                                           |
//+------------------------------------------------------------------+

// Selects our position on this symbol. Magic number scoping means the EA
// will never modify or close a position it did not open.
bool SelectOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != (long)MagicNumber) continue;
      return(true);
   }
   return(false);
}

double GetAtr()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(_atrHandle, 0, 0, 2, atr) < 2)
      return(0.0);
   return(atr[1]);   // value of the bar that just closed
}

string DealCloseReason(ulong deal)
{
   ENUM_DEAL_REASON r = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   switch(r)
   {
      case DEAL_REASON_SL:     return("StopLoss");
      case DEAL_REASON_TP:     return("TakeProfit");
      case DEAL_REASON_EXPERT: return("Expert");
      case DEAL_REASON_CLIENT: return("Manual");
      case DEAL_REASON_SO:     return("StopOut");
      default:                 return("Other");
   }
}
//+------------------------------------------------------------------+
