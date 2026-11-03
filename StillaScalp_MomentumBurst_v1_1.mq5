//+------------------------------------------------------------------+
//| StillaScalp_MomentumBurst_v1_1.mq5                                |
//| EURJPY M5 Momentum Burst Scalping EA — v1.1                       |
//| CHANGES FROM v1.0:                                                |
//|   - Added M15 ADX regime filter (skip ranging markets)            |
//+------------------------------------------------------------------+
#property copyright "Saii / Stilla"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//=================== INPUTS ===================
input group "=== Identification ==="
input long     InpMagic            = 20260722;   // Magic number
input string   InpComment          = "SMS_v1_1"; // Order comment

input group "=== Session Filter (BROKER server time) ==="
input int      InpStartHour        = 10;         // Session start hour (London open, GMT+3 broker = 10)
input int      InpStartMin         = 0;
input int      InpEndHour          = 23;         // Session end hour (NY mid)
input int      InpEndMin           = 0;
input bool     InpCloseAtSessionEnd= true;       // Force-close open position at session end

input group "=== Market Filters ==="
input double   InpMaxSpreadPips    = 1.8;        // Max spread (pips)
input double   InpATRFloorRatio    = 0.8;        // Skip if ATR < ratio x ATR(20-avg)
input int      InpADXPeriod        = 14;         // ADX period (M15)
input double   InpADXMinLevel      = 22.0;       // Min ADX for trending regime (skip if below; 0=off)

input group "=== Entry ==="
input double   InpBurstATRMult     = 1.5;        // Burst candle range >= x * ATR(14)
input int      InpRSIPeriod        = 7;
input double   InpRSILongLevel     = 60.0;
input double   InpRSIShortLevel    = 40.0;

input group "=== Risk & Trade Management ==="
input double   InpRiskPercent      = 0.5;        // Risk per trade (% of equity)
input double   InpSL_ATRMult       = 1.2;        // SL = x * ATR
input double   InpTP1_ATRMult      = 1.0;        // TP1 = x * ATR (close 50%, SL->BE)
input double   InpTP2_ATRMult      = 2.0;        // TP2 = x * ATR (final target)
input double   InpTrail_ATRMult    = 0.8;        // Trailing distance after TP1
input int      InpTimeExitBars     = 12;         // Close if TP1 not hit within N bars
input int      InpSlippagePoints   = 30;         // Max deviation (points)

input group "=== Prop-Rules Engine (daily accounting) ==="
input double   InpDailyLossCapPct  = 2.0;        // Halt day at -X% equity
input double   InpDailyProfitLockPct = 2.5;      // Halt day at +X% equity
input int      InpMaxTradesPerDay  = 8;
input int      InpConsecLossLimit  = 3;          // Losses in a row -> cooldown
input int      InpCooldownMinutes  = 120;

//=================== GLOBALS ===================
int      hATR = INVALID_HANDLE;      // ATR(14) M5
int      hEMA20 = INVALID_HANDLE;    // EMA20 M15
int      hEMA50 = INVALID_HANDLE;    // EMA50 M15
int      hRSI = INVALID_HANDLE;      // RSI(7) M5
int      hADX = INVALID_HANDLE;      // ADX(14) M15 -- NEW in v1.1

datetime g_lastBarTime = 0;
double   g_pip = 0.0;                // 1 pip in price terms

// GlobalVariable keys (persist across VPS restarts)
string GV_DAY, GV_DAYSTART_EQ, GV_TRADES_TODAY, GV_CONSEC_LOSS,
       GV_COOLDOWN_UNTIL, GV_HALTED_DAY;

//=================== HELPERS ===================
string GVKey(const string suffix)
  { return "SMS1_" + _Symbol + "_" + (string)InpMagic + "_" + suffix; }

double GVGet(const string key, const double def)
  { return GlobalVariableCheck(key) ? GlobalVariableGet(key) : def; }

void GVSet(const string key, const double val)
  { GlobalVariableSet(key, val); }

long BrokerDayStamp()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return (long)dt.year * 10000 + dt.mon * 100 + dt.day;
  }

bool InSession()
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = InpStartHour * 60 + InpStartMin;
   int endMin   = InpEndHour * 60 + InpEndMin;
   if(startMin <= endMin) return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin); // overnight session
  }

double SpreadPips()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return 999.0;
   return (t.ask - t.bid) / g_pip;
  }

bool GetBuf(const int handle, const int shift, double &val)
  {
   double b[1];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return false;
   val = b[0];
   return true;
  }

// Our single position (one at a time per symbol+magic)
bool SelectOurPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { ticket = tk; return true; }
     }
   return false;
  }

//=================== DAILY STATE ===================
void RolloverIfNewDay()
  {
   long today = BrokerDayStamp();
   long stored = (long)GVGet(GV_DAY, 0);
   if(stored == today) return;
   GVSet(GV_DAY, (double)today);
   GVSet(GV_DAYSTART_EQ, AccountInfoDouble(ACCOUNT_EQUITY));
   GVSet(GV_TRADES_TODAY, 0);
   GVSet(GV_CONSEC_LOSS, GVGet(GV_CONSEC_LOSS, 0)); // streak carries over days
   GVSet(GV_HALTED_DAY, 0);
   PrintFormat("[SMS] New broker day %I64d | dayStartEquity=%.2f", today,
               AccountInfoDouble(ACCOUNT_EQUITY));
  }

bool DayHalted()
  {
   if((long)GVGet(GV_HALTED_DAY, 0) == BrokerDayStamp()) return true;

   double startEq = GVGet(GV_DAYSTART_EQ, AccountInfoDouble(ACCOUNT_EQUITY));
   if(startEq <= 0) return false;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double chgPct = (eq - startEq) / startEq * 100.0;

   if(chgPct <= -InpDailyLossCapPct)
     {
      GVSet(GV_HALTED_DAY, (double)BrokerDayStamp());
      PrintFormat("[SMS] DAILY LOSS CAP hit (%.2f%%). Halting for the day.", chgPct);
      CloseOurPositionMarket("daily loss cap");
      return true;
     }
   if(chgPct >= InpDailyProfitLockPct)
     {
      GVSet(GV_HALTED_DAY, (double)BrokerDayStamp());
      PrintFormat("[SMS] DAILY PROFIT LOCK hit (+%.2f%%). Halting for the day.", chgPct);
      CloseOurPositionMarket("daily profit lock");
      return true;
     }
   return false;
  }

bool InCooldown()
  {
   double until = GVGet(GV_COOLDOWN_UNTIL, 0);
   return (until > 0 && TimeCurrent() < (datetime)until);
  }

//=================== POSITION MGMT ===================
void CloseOurPositionMarket(const string reason)
  {
   ulong tk;
   if(!SelectOurPosition(tk)) return;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   if(trade.PositionClose(tk))
      PrintFormat("[SMS] Position %I64u closed: %s", tk, reason);
  }

void ManageOpenPosition()
  {
   ulong tk;
   if(!SelectOurPosition(tk)) return;
   if(!PositionSelectByTicket(tk)) return;

   long   type      = PositionGetInteger(POSITION_TYPE);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL     = PositionGetDouble(POSITION_SL);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   datetime openTm  = (datetime)PositionGetInteger(POSITION_TIME);

   double atr;
   if(!GetBuf(hATR, 1, atr)) return;

   MqlTick t; if(!SymbolInfoTick(_Symbol, t)) return;
   double price = (type == POSITION_TYPE_BUY) ? t.bid : t.ask;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string tp1Key = GVKey("TP1_" + (string)tk);
   bool   tp1Done = (GVGet(tp1Key, 0) > 0.5);

   //--- Time exit: TP1 not hit within N bars -> market close
   if(!tp1Done && TimeCurrent() - openTm >= InpTimeExitBars * PeriodSeconds(PERIOD_M5))
     {
      CloseOurPositionMarket("time exit (" + (string)InpTimeExitBars + " bars)");
      return;
     }

   //--- Session end force-close
   if(InpCloseAtSessionEnd && !InSession())
     {
      CloseOurPositionMarket("session end");
      return;
     }

   double gain = (type == POSITION_TYPE_BUY) ? (price - openPrice) : (openPrice - price);

   //--- TP1: close 50%, SL -> breakeven
   if(!tp1Done && gain >= InpTP1_ATRMult * atr)
     {
      double half = volume / 2.0;
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      half = MathFloor(half / step) * step;
      if(half >= vmin && volume - half >= vmin)
        {
         trade.SetExpertMagicNumber(InpMagic);
         trade.SetDeviationInPoints(InpSlippagePoints);
         if(trade.PositionClosePartial(tk, half))
           {
            GVSet(tp1Key, 1);
            double be = NormalizeDouble(openPrice, digits);
            trade.PositionModify(tk, be, PositionGetDouble(POSITION_TP));
            PrintFormat("[SMS] TP1 hit: closed %.2f lots, SL -> BE %.5f", half, be);
           }
        }
      else
        {
         // volume too small to split: just lock BE
         GVSet(tp1Key, 1);
         trade.PositionModify(tk, NormalizeDouble(openPrice, digits),
                              PositionGetDouble(POSITION_TP));
        }
      return;
     }

   //--- Trailing after TP1
   if(tp1Done)
     {
      double trailDist = InpTrail_ATRMult * atr;
      double newSL = (type == POSITION_TYPE_BUY)
                     ? NormalizeDouble(price - trailDist, digits)
                     : NormalizeDouble(price + trailDist, digits);
      bool better = (type == POSITION_TYPE_BUY)
                    ? (newSL > curSL + _Point && newSL > openPrice)
                    : (curSL == 0 || (newSL < curSL - _Point && newSL < openPrice));
      if(better)
         trade.PositionModify(tk, newSL, PositionGetDouble(POSITION_TP));
     }
  }

//=================== ENTRY ===================
double CalcLots(const double slDistance)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0 || slDistance <= 0) return 0;

   double lossPerLot = slDistance / tickSize * tickVal;
   double lots = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < vmin) return 0;          // risk would exceed target with vmin -> skip
   if(lots > vmax) lots = vmax;
   return lots;
  }

void TryEnter()
  {
   //--- Filters -----------------------------------------------------
   if(!InSession())                 return;
   if(DayHalted())                  return;
   if(InCooldown())                 return;
   if((int)GVGet(GV_TRADES_TODAY, 0) >= InpMaxTradesPerDay) return;
   if(SpreadPips() > InpMaxSpreadPips) return;

   ulong tk;
   if(SelectOurPosition(tk))        return;  // one position at a time

   //--- Indicator values (closed bars only) -------------------------
   double atr, ema20, ema50, rsi, adx;
   if(!GetBuf(hATR, 1, atr))   return;
   if(!GetBuf(hEMA20, 1, ema20)) return;
   if(!GetBuf(hEMA50, 1, ema50)) return;
   if(!GetBuf(hRSI, 1, rsi))   return;
   if(!GetBuf(hADX, 1, adx))   return;

   //--- ADX regime filter: skip ranging markets (NEW in v1.1)
   if(InpADXMinLevel > 0.0 && adx < InpADXMinLevel)
     {
      // PrintFormat("[SMS] Skip: ADX=%.1f < %.1f (ranging)", adx, InpADXMinLevel);
      return;
     }

   //--- ATR floor: dead market filter
   double atrArr[21];
   if(CopyBuffer(hATR, 0, 1, 20, atrArr) != 20) return;
   double atrAvg = 0;
   for(int i = 0; i < 20; i++) atrAvg += atrArr[i];
   atrAvg /= 20.0;
   if(atr < InpATRFloorRatio * atrAvg) return;

   //--- Bias (M15)
   int bias = 0;                       // +1 long only, -1 short only
   if(ema20 > ema50) bias = 1;
   else if(ema20 < ema50) bias = -1;
   else return;

   //--- Burst trigger candle = last closed M5 bar
   double hi = iHigh(_Symbol, PERIOD_M5, 1);
   double lo = iLow(_Symbol, PERIOD_M5, 1);
   double op = iOpen(_Symbol, PERIOD_M5, 1);
   double cl = iClose(_Symbol, PERIOD_M5, 1);
   double range = hi - lo;
   if(range < InpBurstATRMult * atr) return;

   bool longSetup  = (bias == 1)  && (cl > op) && (rsi >= InpRSILongLevel);
   bool shortSetup = (bias == -1) && (cl < op) && (rsi <= InpRSIShortLevel);
   if(!longSetup && !shortSetup) return;

   //--- Build order -------------------------------------------------
   MqlTick t; if(!SymbolInfoTick(_Symbol, t)) return;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slDist = InpSL_ATRMult * atr;
   double tpDist = InpTP2_ATRMult * atr;
   double lots = CalcLots(slDist);
   if(lots <= 0) { Print("[SMS] Lot calc = 0, skip"); return; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = false;
   if(longSetup)
      ok = trade.Buy(lots, _Symbol, t.ask,
                     NormalizeDouble(t.ask - slDist, digits),
                     NormalizeDouble(t.ask + tpDist, digits), InpComment);
   else
      ok = trade.Sell(lots, _Symbol, t.bid,
                      NormalizeDouble(t.bid + slDist, digits),
                      NormalizeDouble(t.bid - tpDist, digits), InpComment);

   if(ok)
      PrintFormat("[SMS] ENTRY %s %.2f lots | ATR=%.5f ADX=%.1f SL=%.1fp TP=%.1fp RSI=%.1f",
                  longSetup ? "BUY" : "SELL", lots, atr, adx,
                  slDist / g_pip, tpDist / g_pip, rsi);
   else
      PrintFormat("[SMS] Entry failed: %d %s", trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
  }

//=================== TRADE TRANSACTIONS ===================
// Counts trades/day, tracks per-position P/L, consecutive-loss cooldown.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long   magic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(magic != InpMagic || symbol != _Symbol) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long posID = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   if(entry == DEAL_ENTRY_IN)
     {
      GVSet(GV_TRADES_TODAY, GVGet(GV_TRADES_TODAY, 0) + 1);
      PrintFormat("[SMS] Trades today: %d", (int)GVGet(GV_TRADES_TODAY, 0));
      return;
     }

   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      string pnlKey = GVKey("PNL_" + (string)posID);
      GVSet(pnlKey, GVGet(pnlKey, 0) + pnl);

      // Position fully closed? (partial closes produce multiple OUT deals)
      bool stillOpen = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk2 = PositionGetTicket(i);
         if(tk2 != 0 && PositionGetInteger(POSITION_IDENTIFIER) == posID)
           { stillOpen = true; break; }
        }
      if(stillOpen) return;

      double total = GVGet(pnlKey, 0);
      GlobalVariableDel(pnlKey);
      GlobalVariableDel(GVKey("TP1_" + (string)posID));

      double eps = AccountInfoDouble(ACCOUNT_EQUITY) * 0.0002; // ~BE band
      if(total < -eps)
        {
         double streak = GVGet(GV_CONSEC_LOSS, 0) + 1;
         GVSet(GV_CONSEC_LOSS, streak);
         PrintFormat("[SMS] LOSS %.2f | consecutive: %d", total, (int)streak);
         if((int)streak >= InpConsecLossLimit)
           {
            GVSet(GV_COOLDOWN_UNTIL,
                  (double)(TimeCurrent() + InpCooldownMinutes * 60));
            GVSet(GV_CONSEC_LOSS, 0);
            PrintFormat("[SMS] %d losses in a row -> cooldown %d min",
                        InpConsecLossLimit, InpCooldownMinutes);
           }
        }
      else if(total > eps)
        {
         GVSet(GV_CONSEC_LOSS, 0);
         PrintFormat("[SMS] WIN %.2f | streak reset", total);
        }
      else
         PrintFormat("[SMS] BREAKEVEN %.2f | streak unchanged", total);
     }
  }

//=================== LIFECYCLE ===================
int OnInit()
  {
   if(_Period != PERIOD_M5)
      Print("[SMS] WARNING: attach to M5 chart. Indicators are fixed to M5/M15 anyway.");

   g_pip = (_Digits == 3 || _Digits == 5) ? 10 * _Point : _Point;

   GV_DAY            = GVKey("DAY");
   GV_DAYSTART_EQ    = GVKey("DAYSTART_EQ");
   GV_TRADES_TODAY   = GVKey("TRADES_TODAY");
   GV_CONSEC_LOSS    = GVKey("CONSEC_LOSS");
   GV_COOLDOWN_UNTIL = GVKey("COOLDOWN_UNTIL");
   GV_HALTED_DAY     = GVKey("HALTED_DAY");

   hATR   = iATR(_Symbol, PERIOD_M5, 14);
   hEMA20 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   hADX   = iADX(_Symbol, PERIOD_M15, InpADXPeriod);

   if(hATR == INVALID_HANDLE || hEMA20 == INVALID_HANDLE ||
      hEMA50 == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hADX == INVALID_HANDLE)
     {
      Print("[SMS] Indicator handle creation failed");
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   RolloverIfNewDay();
   PrintFormat("[SMS] StillaScalp Momentum Burst v1.1 initialized on %s | ADX filter=%.1f",
               _Symbol, InpADXMinLevel);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   IndicatorRelease(hATR);
   IndicatorRelease(hEMA20);
   IndicatorRelease(hEMA50);
   IndicatorRelease(hRSI);
   IndicatorRelease(hADX);
  }

void OnTick()
  {
   RolloverIfNewDay();

   // Every tick: manage open position + enforce daily caps live
   ManageOpenPosition();
   if(DayHalted()) return;

   // Entry decisions only on new M5 bar
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   TryEnter();
  }
//+------------------------------------------------------------------+