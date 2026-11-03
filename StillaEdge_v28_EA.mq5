//+------------------------------------------------------------------+
//|                                            StillaEdge_v21_EA.mq5 |
//|  NON-TRADING Expert Advisor (decision-support dashboard)          |
//|  v2.1 — converted from indicator to EA because MQL5 forbids       |
//|  WebRequest() inside indicators. This EA NEVER opens orders.      |
//|                                                                   |
//|  v2.2 display fixes (logic unchanged from v2.1):                  |
//|   1. Zones are BORDER-ONLY now. MT5 object fills are opaque,      |
//|      so filled confluence zones flooded the chart with gold.      |
//|      Confluence = thick solid gold border, others = dotted.       |
//|   2. Far-away zones hidden: only zones within N x ATR of price    |
//|      are drawn (InpZoneProxATR). Zone rectangles only span the    |
//|      last InpZoneDrawBars bars, not full history.                 |
//|   3. Dashboard label anchor bug fixed — text was rendered         |
//|      OUTSIDE the panel box (left of it, over candles).            |
//|                                                                   |
//|  v2.1 features: confluence tolerance, EA-context webhook,         |
//|  OnTimer dashboard, arrow auto-cleanup, spread filter, PAUSE.     |
//|                                                                   |
//|  All signal logic uses CLOSED bars only (no repainting).          |
//|  Honest scoring: historical zone bounce rate + momentum adjust.   |
//|  Decision support only — NOT a win-rate guarantee.                |
//+------------------------------------------------------------------+
#property copyright "Stilla"
#property version   "2.80"
#property description "Non-trading MTF assistant EA: SR confluence zones, trend/momentum matrix, entry setups, Telegram webhook."

//--- inputs -------------------------------------------------------
input group "=== Zones ==="
input int    InpLookbackLTF   = 400;   // Bars scanned on 15M/30M/1H
input int    InpLookbackHTF   = 250;   // Bars scanned on 4H/1D
input int    InpWing          = 3;     // Fractal wing size
input double InpZoneWidthATR  = 0.50;  // Zone half-width (x that TF's ATR)
input int    InpMinTouches    = 2;     // Min touches to keep a zone
input int    InpMaxZonesPerTF = 4;     // Max zones kept per timeframe
input double InpConfTolATR    = 0.50;  // Confluence gap tolerance (x ATR 1H)
input double InpZoneProxATR   = 8.0;   // Draw only zones within N x ATR of price (0 = all)
input int    InpZoneDrawBars  = 120;   // Zone rectangles span last N bars only

input group "=== Trend / Momentum ==="
input int    InpEMAfast       = 50;
input int    InpEMAslow       = 200;
input int    InpRSIPeriod     = 14;
input double InpRSIBull       = 52.0;
input double InpRSIBear       = 48.0;

input group "=== Entry Setup ==="
input bool   InpConfluentOnly = true;  // Setups only inside confluence zones
input double InpVolFactor     = 1.2;   // Volume > factor x SMA20(tick volume)
input double InpMinScore      = 55.0;  // Min score % to show a setup
input double InpSLbufATR      = 0.50;  // SL buffer beyond zone (x ATR)
input double InpMinRR         = 2.0;   // Minimum Reward:Risk shown

input group "=== Filters ==="
input int    InpMaxSpreadPts  = 35;    // Max spread (points), 0 = filter off
input int    InpDashRefreshSec= 5;     // Dashboard refresh interval (sec)
input int    InpArrowKeepBars = 500;   // Delete setup arrows older than N bars

input group "=== Alerts ==="
input bool   InpAlertPopup    = true;
input bool   InpAlertPush     = false;
input string InpWebhookURL    = "";    // e.g. https://stailla.xyz/webhook/stillaedge-signal (whitelist in MT5!)
input bool   InpAlertAlign    = true;
input int    InpAlignCooldownMin = 240; // Re-alert same alignment direction after N minutes

input group "=== Signal Tracking / Daily Report ==="
input bool   InpTrackOutcomes = true;  // Auto-track each setup until TP or SL is hit
input int    InpReportHour    = 21;    // Server hour to send the daily report
input bool   InpLogToCSV      = true;  // Append journal to MQL5\Files\StillaEdge_journal.csv

input group "=== R:R Visual Boxes ==="
input bool   InpShowRRBoxes   = true;  // Draw shaded SL (red) / TP (cyan) boxes on setups
input int    InpRRBoxBars     = 20;    // Box width in bars (extends right from signal bar)

input group "=== AI Analysis Snapshot / Calendar ==="
input bool   InpSnapshotOn    = true;  // Send market snapshot for AI analysis
input int    InpSnapshotHours = 4;     // Snapshot interval (hours) -> 3-4x per trading day
input bool   InpCalendarOn    = false; // Daily economic calendar digest (enable on ONE chart only!)
input int    InpCalendarHour  = 4;     // Server hour to send calendar digest

//--- constants ----------------------------------------------------
#define PFX  "SE22_"
#define NTF  5
ENUM_TIMEFRAMES g_tf[NTF]   = {PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1};
string          g_tfn[NTF]  = {"15M", "30M", "1H", "4H", "1D"};
color           g_tfc[NTF]  = {clrSilver, clrMediumPurple, clrDodgerBlue, clrDarkOrange, clrCrimson};
bool            g_show[NTF] = {false, true, true, true, true};

//--- handles ------------------------------------------------------
int hEMAf[NTF], hEMAs[NTF], hRSI[NTF];
int hATRcur = INVALID_HANDLE;

//--- zone storage -------------------------------------------------
struct MZone
  {
   int    tf;
   double top, bottom;
   int    touches, bounces;
   bool   conf;
   double BounceRate() const { return touches > 0 ? 100.0 * bounces / touches : 0.0; }
  };
MZone  g_z[];
double g_tfATR[NTF];

//--- state --------------------------------------------------------
datetime g_lastBar = 0;
int      g_trend[NTF], g_mom[NTF];
int      g_lastAlign = 0;
int      g_lastAlertedAlignDir = 0;
datetime g_lastAlignAlertTime  = 0;

//--- v2.5 signal tracking ----------------------------------------
struct Tracked
  {
   datetime t0;
   int      dir;
   double   entry, sl, tp, score;
  };
Tracked  g_openSetups[];
int      g_winsToday = 0, g_lossToday = 0;
int      g_winsTotal = 0, g_lossTotal = 0;
int      g_lastReportDay = -1;
int      g_counterDay    = -1;
datetime g_lastSnapTime    = 0;
int      g_lastCalendarDay = -1;
string   g_lastSetup = "none yet";
double   g_atrNow = 0;
bool     g_paused = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   for(int i = 0; i < NTF; i++)
     {
      hEMAf[i] = INVALID_HANDLE;
      hEMAs[i] = INVALID_HANDLE;
      hRSI[i]  = INVALID_HANDLE;
      g_tfATR[i] = 0;
     }
   for(int i = 2; i < NTF; i++)
     {
      hEMAf[i] = iMA(_Symbol, g_tf[i], InpEMAfast, 0, MODE_EMA, PRICE_CLOSE);
      hEMAs[i] = iMA(_Symbol, g_tf[i], InpEMAslow, 0, MODE_EMA, PRICE_CLOSE);
      if(hEMAf[i] == INVALID_HANDLE || hEMAs[i] == INVALID_HANDLE) return INIT_FAILED;
     }
   for(int i = 0; i < 2; i++)
     {
      hRSI[i] = iRSI(_Symbol, g_tf[i], InpRSIPeriod, PRICE_CLOSE);
      if(hRSI[i] == INVALID_HANDLE) return INIT_FAILED;
     }
   hATRcur = iATR(_Symbol, _Period, 14);
   if(hATRcur == INVALID_HANDLE) return INIT_FAILED;

   CreateButtons();
   EventSetTimer(MathMax(2, InpDashRefreshSec));

   //--- v2.7: restore alignment alert state across restarts/migrations
   string gvd = PFX + _Symbol + "_adir";
   string gvt = PFX + _Symbol + "_atime";
   if(GlobalVariableCheck(gvd)) g_lastAlertedAlignDir = (int)GlobalVariableGet(gvd);
   if(GlobalVariableCheck(gvt)) g_lastAlignAlertTime  = (datetime)GlobalVariableGet(gvt);

   Print("StillaEdge v2.8 EA started (non-trading). Webhook: ",
         StringLen(InpWebhookURL) > 0 ? InpWebhookURL : "disabled");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Heavy work: once per new chart-TF bar                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- v2.5: tick-accurate outcome tracking + daily report (cheap)
   if(InpTrackOutcomes) CheckOutcomes();
   CheckDailyReport();

   datetime bt = iTime(_Symbol, _Period, 0);
   if(bt == 0 || bt == g_lastBar) return;
   g_lastBar = bt;

   double atr[];
   if(CopyBuffer(hATRcur, 0, 0, 3, atr) < 3) return;
   ArraySetAsSeries(atr, true);
   g_atrNow = atr[1];
   if(g_atrNow <= 0) return;

   RebuildAllZones();
   MarkConfluence();
   DrawZonesNow();
   PruneOldArrows();
   if(!g_paused)
      DetectSetup();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Light work: dashboard every N seconds (never per tick)            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateTrendMomentum();
   DrawDashboard();
   CheckAlignmentAlert();
   CheckSnapshot();
   CheckCalendarDigest();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Buttons: 5 timeframe toggles + PAUSE                              |
//+------------------------------------------------------------------+
void CreateButtons()
  {
   for(int i = 0; i < NTF; i++)
      MakeBtn(PFX + "btn_" + g_tfn[i], 10 + i * 52, g_tfn[i],
              g_show[i] ? g_tfc[i] : clrDimGray, g_show[i]);
   MakeBtn(PFX + "btn_PAUSE", 10 + NTF * 52 + 8, "PAUSE",
           g_paused ? clrRed : clrDimGray, g_paused);
  }

void MakeBtn(const string n, const int x, const string txt, const color bg, const bool state)
  {
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_LOWER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, 30);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, txt == "PAUSE" ? 58 : 48);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, 22);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_STATE, state);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   if(sparam == PFX + "btn_PAUSE")
     {
      g_paused = !g_paused;
      MakeBtn(PFX + "btn_PAUSE", 10 + NTF * 52 + 8, "PAUSE",
              g_paused ? clrRed : clrDimGray, g_paused);
      Print("StillaEdge signals ", g_paused ? "PAUSED (news mode)" : "RESUMED");
      ChartRedraw();
      return;
     }
   for(int i = 0; i < NTF; i++)
     {
      if(sparam != PFX + "btn_" + g_tfn[i]) continue;
      g_show[i] = !g_show[i];
      MakeBtn(PFX + "btn_" + g_tfn[i], 10 + i * 52, g_tfn[i],
              g_show[i] ? g_tfc[i] : clrDimGray, g_show[i]);
      DrawZonesNow();
      ChartRedraw();
      return;
     }
  }

//+------------------------------------------------------------------+
void RebuildAllZones()
  {
   ArrayFree(g_z);
   for(int i = 0; i < NTF; i++)
      BuildZonesForTF(i);
  }

//+------------------------------------------------------------------+
void BuildZonesForTF(const int tfIdx)
  {
   int lookback = (tfIdx >= 3) ? InpLookbackHTF : InpLookbackLTF;
   int need = lookback + InpWing + 5;

   double hi[], lo[], cl[];
   if(CopyHigh(_Symbol, g_tf[tfIdx], 0, need, hi)  < need) return;
   if(CopyLow(_Symbol, g_tf[tfIdx], 0, need, lo)   < need) return;
   if(CopyClose(_Symbol, g_tf[tfIdx], 0, need, cl) < need) return;
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);

   double atr = 0;
   for(int i = 1; i <= 14; i++)
      atr += MathMax(hi[i], cl[i + 1]) - MathMin(lo[i], cl[i + 1]);
   atr /= 14.0;
   if(atr <= 0) return;
   g_tfATR[tfIdx] = atr;
   double halfW = atr * InpZoneWidthATR;

   double levels[];
   int nLv = 0;
   for(int i = InpWing + 1; i <= lookback; i++)
     {
      bool isHigh = true, isLow = true;
      for(int w = 1; w <= InpWing; w++)
        {
         if(hi[i] <= hi[i - w] || hi[i] <= hi[i + w]) isHigh = false;
         if(lo[i] >= lo[i - w] || lo[i] >= lo[i + w]) isLow  = false;
         if(!isHigh && !isLow) break;
        }
      if(isHigh) { ArrayResize(levels, nLv + 1); levels[nLv++] = hi[i]; }
      if(isLow)  { ArrayResize(levels, nLv + 1); levels[nLv++] = lo[i]; }
     }
   if(nLv == 0) return;

   MZone zs[];
   for(int k = 0; k < nLv; k++)
     {
      bool merged = false;
      for(int z = 0; z < ArraySize(zs); z++)
        {
         double mid = (zs[z].top + zs[z].bottom) / 2.0;
         if(MathAbs(levels[k] - mid) <= halfW * 2.0)
           {
            zs[z].top    = MathMin(MathMax(zs[z].top,    levels[k] + halfW), mid + halfW * 2.0);
            zs[z].bottom = MathMax(MathMin(zs[z].bottom, levels[k] - halfW), mid - halfW * 2.0);
            merged = true;
            break;
           }
        }
      if(!merged)
        {
         int n = ArraySize(zs);
         ArrayResize(zs, n + 1);
         zs[n].tf = tfIdx;
         zs[n].top = levels[k] + halfW;
         zs[n].bottom = levels[k] - halfW;
         zs[n].touches = 0;
         zs[n].bounces = 0;
         zs[n].conf = false;
        }
     }

   for(int z = 0; z < ArraySize(zs); z++)
     {
      int lastTouch = -100;
      for(int i = lookback; i >= 2; i--)
        {
         if(!(hi[i] >= zs[z].bottom && lo[i] <= zs[z].top)) continue;
         if(lastTouch != -100 && (lastTouch - i) < InpWing) continue;
         lastTouch = i;
         zs[z].touches++;
         if(cl[i] > zs[z].top || cl[i] < zs[z].bottom)
           {
            bool fromBelow = (cl[i + 1] <= zs[z].bottom);
            bool fromAbove = (cl[i + 1] >= zs[z].top);
            if((fromBelow && cl[i] < zs[z].bottom) || (fromAbove && cl[i] > zs[z].top))
               zs[z].bounces++;
           }
        }
     }

   double px = cl[1];
   MZone keep[];
   for(int z = 0; z < ArraySize(zs); z++)
      if(zs[z].touches >= InpMinTouches)
        {
         int n = ArraySize(keep);
         ArrayResize(keep, n + 1);
         keep[n] = zs[z];
        }
   int total = ArraySize(keep);
   for(int a = 0; a < total - 1; a++)
     {
      int best = a;
      for(int b = a + 1; b < total; b++)
        {
         double da = MathAbs((keep[best].top + keep[best].bottom) / 2.0 - px);
         double db = MathAbs((keep[b].top   + keep[b].bottom)   / 2.0 - px);
         if(db < da) best = b;
        }
      if(best != a) { MZone s = keep[a]; keep[a] = keep[best]; keep[best] = s; }
     }
   int nKeep = MathMin(InpMaxZonesPerTF, total);
   for(int z = 0; z < nKeep; z++)
     {
      int n = ArraySize(g_z);
      ArrayResize(g_z, n + 1);
      g_z[n] = keep[z];
     }
  }

//+------------------------------------------------------------------+
//| v2.1: overlap OR gap within InpConfTolATR x ATR(1H) = confluence  |
//+------------------------------------------------------------------+
void MarkConfluence()
  {
   double tol = g_tfATR[2] * InpConfTolATR;   // ATR of 1H
   if(tol <= 0) tol = g_atrNow * InpConfTolATR;

   for(int a = 0; a < ArraySize(g_z); a++)
     {
      if(g_z[a].tf < 3) continue;             // HTF = 4H / 1D
      for(int b = 0; b < ArraySize(g_z); b++)
        {
         if(g_z[b].tf != 1 && g_z[b].tf != 2) continue; // LTF = 30M / 1H
         double gap = MathMax(g_z[a].bottom, g_z[b].bottom) -
                      MathMin(g_z[a].top,    g_z[b].top);
         // gap <= 0 means overlap; 0 < gap <= tol means near-miss => still confluence
         if(gap <= tol)
           {
            g_z[a].conf = true;
            g_z[b].conf = true;
           }
        }
     }
  }

//+------------------------------------------------------------------+
void DrawZonesNow()
  {
   ObjectsDeleteAll(0, PFX + "zone");
   ObjectsDeleteAll(0, PFX + "zlbl");

   datetime t[];
   int got = CopyTime(_Symbol, _Period, 0, MathMax(30, InpZoneDrawBars) + 5, t);
   if(got < 20) return;
   ArraySetAsSeries(t, true);
   int startIdx = got - 1;

   double px   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double prox = (g_atrNow > 0) ? InpZoneProxATR * g_atrNow : 0;

   for(int z = 0; z < ArraySize(g_z); z++)
     {
      if(!g_show[g_z[z].tf]) continue;

      double mid = (g_z[z].top + g_z[z].bottom) / 2.0;
      if(prox > 0 && MathAbs(mid - px) > prox) continue;   // v2.2: hide far zones

      color col = g_z[z].conf ? clrGold : g_tfc[g_z[z].tf];
      string rn = PFX + "zone_" + IntegerToString(z);
      ObjectCreate(0, rn, OBJ_RECTANGLE, 0, t[startIdx], g_z[z].bottom, t[0], g_z[z].top);
      ObjectSetInteger(0, rn, OBJPROP_COLOR, col);
      ObjectSetInteger(0, rn, OBJPROP_FILL, false);        // v2.2: MT5 fills are opaque -> never fill
      ObjectSetInteger(0, rn, OBJPROP_BACK, true);
      ObjectSetInteger(0, rn, OBJPROP_WIDTH, g_z[z].conf ? 2 : 1);
      ObjectSetInteger(0, rn, OBJPROP_STYLE, g_z[z].conf ? STYLE_SOLID : STYLE_DOT);
      ObjectSetInteger(0, rn, OBJPROP_SELECTABLE, false);

      string ln  = PFX + "zlbl_" + IntegerToString(z);
      string txt = StringFormat("%s%s t%d b%.0f%%",
                                g_z[z].conf ? "* " : "",
                                g_tfn[g_z[z].tf], g_z[z].touches, g_z[z].BounceRate());
      // v2.3: label always in its TF color (gold rectangles made labels
      // indistinguishable). Stagger label x-position per TF to avoid overlap.
      int lx = 5 + g_z[z].tf * 12;
      if(lx >= got) lx = 5;
      ObjectCreate(0, ln, OBJ_TEXT, 0, t[lx], g_z[z].top);
      ObjectSetString(0, ln, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, g_tfc[g_z[z].tf]);
      ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//| Memory cleanup: delete setup arrows older than N bars             |
//+------------------------------------------------------------------+
void PruneOldArrows()
  {
   datetime cutoff = TimeCurrent() - (datetime)PeriodSeconds() * InpArrowKeepBars;
   int total = ObjectsTotal(0, 0, OBJ_ARROW);
   for(int i = total - 1; i >= 0; i--)
     {
      string n = ObjectName(0, i, 0, OBJ_ARROW);
      if(StringFind(n, PFX + "arr_") != 0) continue;
      if((datetime)ObjectGetInteger(0, n, OBJPROP_TIME) < cutoff)
         ObjectDelete(0, n);
     }
  }

//+------------------------------------------------------------------+
void UpdateTrendMomentum()
  {
   for(int i = 2; i < NTF; i++)
     {
      double f[], s[];
      g_trend[i] = 0;
      if(CopyBuffer(hEMAf[i], 0, 1, 1, f) < 1) continue;
      if(CopyBuffer(hEMAs[i], 0, 1, 1, s) < 1) continue;
      double c = iClose(_Symbol, g_tf[i], 1);
      if(c > f[0] && f[0] > s[0])      g_trend[i] = +1;
      else if(c < f[0] && f[0] < s[0]) g_trend[i] = -1;
     }
   for(int i = 0; i < 2; i++)
     {
      double r[];
      g_mom[i] = 0;
      if(CopyBuffer(hRSI[i], 0, 1, 2, r) < 2) continue;
      ArraySetAsSeries(r, true);
      if(r[0] > InpRSIBull && r[0] >= r[1])      g_mom[i] = +1;
      else if(r[0] < InpRSIBear && r[0] <= r[1]) g_mom[i] = -1;
     }
  }

//+------------------------------------------------------------------+
int AlignmentDir()
  {
   if(g_trend[2] == +1 && g_trend[3] == +1 && g_trend[4] == +1 &&
      g_mom[0] == +1 && g_mom[1] == +1) return +1;
   if(g_trend[2] == -1 && g_trend[3] == -1 && g_trend[4] == -1 &&
      g_mom[0] == -1 && g_mom[1] == -1) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
void CheckAlignmentAlert()
  {
   int dir = AlignmentDir();
   g_lastAlign = dir;
   if(dir == 0 || !InpAlertAlign) return;   // MIXED flicker does NOT reset anything

   // v2.8: re-read the SHARED terminal globals every time, so two charts of
   // the same symbol (e.g. USDJPY H1 + H4) never both fire. v2.7 only read
   // them once at OnInit, leaving a race between instances.
   string gvd = PFX + _Symbol + "_adir";
   string gvt = PFX + _Symbol + "_atime";
   if(GlobalVariableCheck(gvd)) g_lastAlertedAlignDir = (int)GlobalVariableGet(gvd);
   if(GlobalVariableCheck(gvt)) g_lastAlignAlertTime  = (datetime)GlobalVariableGet(gvt);

   // v2.4: alert once per direction. Brief drops to MIXED and back to the
   // same direction no longer re-alert. Same direction persisting gets a
   // heartbeat only after the cooldown.
   bool newDirection = (dir != g_lastAlertedAlignDir);
   bool cooledDown   = (TimeCurrent() - g_lastAlignAlertTime >= (datetime)InpAlignCooldownMin * 60);
   if(!newDirection && !cooledDown) return;

   g_lastAlertedAlignDir = dir;
   g_lastAlignAlertTime  = TimeCurrent();
   GlobalVariableSet(PFX + _Symbol + "_adir",  (double)dir);
   GlobalVariableSet(PFX + _Symbol + "_atime", (double)g_lastAlignAlertTime);

   string msg = "StillaEdge [" + _Symbol + "] STRONG TREND ALIGNMENT: " +
                (dir > 0 ? "BULLISH" : "BEARISH") +
                (newDirection ? "" : " (still active)");
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   SendWebhook("alignment", dir > 0 ? "BULL" : "BEAR", 0, 0, 0, 0);
  }

//+------------------------------------------------------------------+
void DrawDashboard()
  {
   int W = 230, RH = 18, rows = 11;
   string bg = PFX + "dash_bg";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, W + 10);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, W);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, rows * RH + 12);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,24,32');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
     }

   long sprd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool sprdBad = (InpMaxSpreadPts > 0 && sprd > InpMaxSpreadPts);

   int y = 26;
   Cell("h",  "StillaEdge v2.8  " + _Symbol, clrWhite, y);                 y += RH;
   Cell("t4", "1D  Trend : " + DirTxt(g_trend[4]), DirCol(g_trend[4]), y); y += RH;
   Cell("t3", "4H  Trend : " + DirTxt(g_trend[3]), DirCol(g_trend[3]), y); y += RH;
   Cell("t2", "1H  Trend : " + DirTxt(g_trend[2]), DirCol(g_trend[2]), y); y += RH;
   Cell("m1", "30M Momo  : " + DirTxt(g_mom[1]),   DirCol(g_mom[1]),  y);  y += RH;
   Cell("m0", "15M Momo  : " + DirTxt(g_mom[0]),   DirCol(g_mom[0]),  y);  y += RH;

   int dir = AlignmentDir();
   string at = dir == 0 ? "Alignment : MIXED"
                        : ("* STRONG " + (string)(dir > 0 ? "BULL" : "BEAR") + " ALIGNMENT *");
   Cell("al", at, dir == 0 ? clrSilver : (dir > 0 ? clrLime : clrRed), y);       y += RH;
   string st = g_paused ? "SIGNALS PAUSED (news mode)"
                        : StringFormat("Spread %d pts %s", (int)sprd, sprdBad ? "> MAX (blocked)" : "OK");
   Cell("sp", st, (g_paused || sprdBad) ? clrOrange : clrSilver, y);             y += RH;
   Cell("ls", "Last: " + StringSubstr(g_lastSetup, 0, 34), clrGold, y);          y += RH;
   int cls = g_winsToday + g_lossToday;
   Cell("td", StringFormat("Today: %dW/%dL%s | Open %d",
        g_winsToday, g_lossToday,
        cls > 0 ? StringFormat(" (%.0f%%)", 100.0 * g_winsToday / cls) : "",
        ArraySize(g_openSetups)),
        g_lossToday > g_winsToday ? clrOrange : clrLime, y);                     y += RH;
   Cell("dc", "Stats-based guide, not a guarantee", clrGray, y);
  }

void Cell(const string id, const string txt, const color col, const int y)
  {
   string n = PFX + "dash_" + id;
   if(ObjectFind(0, n) < 0)
     {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      // v2.2 fix: anchor text's RIGHT edge 20px from chart's right edge,
      // so it sits INSIDE the panel box (box spans 10..240px from right)
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, col);
  }

string DirTxt(const int d) { return d > 0 ? "UP" : (d < 0 ? "DOWN" : "FLAT"); }
color  DirCol(const int d) { return d > 0 ? clrLime : (d < 0 ? clrRed : clrSilver); }

//+------------------------------------------------------------------+
void DetectSetup()
  {
   //--- v2.1: max spread filter (blocks fake setups in news volatility)
   if(InpMaxSpreadPts > 0 &&
      SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPts)
      return;

   double o[], h[], l[], c[];
   long   tv[];
   datetime tm[];
   int need = 30;
   if(CopyOpen(_Symbol, _Period, 0, need, o)  < need) return;
   if(CopyHigh(_Symbol, _Period, 0, need, h)  < need) return;
   if(CopyLow(_Symbol, _Period, 0, need, l)   < need) return;
   if(CopyClose(_Symbol, _Period, 0, need, c) < need) return;
   if(CopyTickVolume(_Symbol, _Period, 0, need, tv) < need) return;
   if(CopyTime(_Symbol, _Period, 0, need, tm) < need) return;
   ArraySetAsSeries(o, true);  ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);  ArraySetAsSeries(c, true);
   ArraySetAsSeries(tv, true); ArraySetAsSeries(tm, true);

   double vsum = 0;
   for(int i = 2; i <= 21; i++) vsum += (double)tv[i];
   bool volOK = ((double)tv[1] > InpVolFactor * (vsum / 20.0));

   double px  = c[1];
   double rng = h[1] - l[1];
   if(rng <= 0) return;

   bool bullPin    = ((c[1] - l[1]) / rng >= 0.60) && ((MathMin(o[1], c[1]) - l[1]) / rng >= 0.50);
   bool bearPin    = ((h[1] - c[1]) / rng >= 0.60) && ((h[1] - MathMax(o[1], c[1])) / rng >= 0.50);
   bool bullEngulf = (c[2] < o[2] && c[1] > o[1] && c[1] >= o[2] && o[1] <= c[2]);
   bool bearEngulf = (c[2] > o[2] && c[1] < o[1] && c[1] <= o[2] && o[1] >= c[2]);

   for(int z = 0; z < ArraySize(g_z); z++)
     {
      if(InpConfluentOnly && !g_z[z].conf) continue;
      if(!InpConfluentOnly && !g_z[z].conf && g_z[z].tf < 3) continue;

      double mid = (g_z[z].top + g_z[z].bottom) / 2.0;
      bool isRes = (mid > px);

      if(!isRes &&
         l[1] <= g_z[z].top && l[1] >= g_z[z].bottom - g_atrNow &&
         c[1] > g_z[z].top &&
         (bullPin || bullEngulf) && volOK &&
         g_mom[0] >= 0 && g_mom[1] >= 0 && (g_mom[0] == 1 || g_mom[1] == 1))
        {
         double score = Score(g_z[z], +1);
         if(score < InpMinScore) continue;
         double entry = c[1];
         double sl    = g_z[z].bottom - InpSLbufATR * g_atrNow;
         double tp    = NextZoneTarget(entry, +1);
         double minTP = entry + InpMinRR * (entry - sl);
         if(tp < minTP) tp = minTP;
         Emit(+1, z, entry, sl, tp, score, tm[1], l[1], bullPin ? "PinBar" : "Engulf");
         return;
        }

      if(isRes &&
         h[1] >= g_z[z].bottom && h[1] <= g_z[z].top + g_atrNow &&
         c[1] < g_z[z].bottom &&
         (bearPin || bearEngulf) && volOK &&
         g_mom[0] <= 0 && g_mom[1] <= 0 && (g_mom[0] == -1 || g_mom[1] == -1))
        {
         double score = Score(g_z[z], -1);
         if(score < InpMinScore) continue;
         double entry = c[1];
         double sl    = g_z[z].top + InpSLbufATR * g_atrNow;
         double tp    = NextZoneTarget(entry, -1);
         double minTP = entry - InpMinRR * (sl - entry);
         if(tp > minTP) tp = minTP;
         Emit(-1, z, entry, sl, tp, score, tm[1], h[1], bearPin ? "PinBar" : "Engulf");
         return;
        }
     }
  }

//+------------------------------------------------------------------+
double Score(const MZone &zn, const int dir)
  {
   double s = zn.BounceRate();
   if(zn.conf) s += 6;
   s += 4 * ((g_trend[2] == dir) + (g_trend[3] == dir) + (g_trend[4] == dir));
   s -= 4 * ((g_trend[2] == -dir) + (g_trend[3] == -dir) + (g_trend[4] == -dir));
   if(AlignmentDir() == dir) s += 5;
   return MathMax(5.0, MathMin(90.0, s));
  }

//+------------------------------------------------------------------+
double NextZoneTarget(const double entry, const int dir)
  {
   double best = (dir > 0) ? DBL_MAX : -DBL_MAX;
   for(int z = 0; z < ArraySize(g_z); z++)
     {
      if(g_z[z].tf < 2) continue;
      if(dir > 0 && g_z[z].bottom > entry && g_z[z].bottom < best) best = g_z[z].bottom;
      if(dir < 0 && g_z[z].top   < entry && g_z[z].top   > best)   best = g_z[z].top;
     }
   if(best == DBL_MAX || best == -DBL_MAX)
      return entry + dir * InpMinRR * g_atrNow * 2.0;
   return best;
  }

//+------------------------------------------------------------------+
void Emit(const int dir, const int zi, const double entry, const double sl,
          const double tp, const double score, const datetime t1,
          const double extreme, const string pattern)
  {
   //--- arrow object (kept in history, auto-pruned by PruneOldArrows)
   string an = PFX + "arr_" + IntegerToString((long)t1);
   double ap = (dir > 0) ? extreme - 0.3 * g_atrNow : extreme + 0.3 * g_atrNow;
   ObjectCreate(0, an, OBJ_ARROW, 0, t1, ap);
   ObjectSetInteger(0, an, OBJPROP_ARROWCODE, dir > 0 ? 233 : 234);
   ObjectSetInteger(0, an, OBJPROP_COLOR, dir > 0 ? clrDodgerBlue : clrOrangeRed);
   ObjectSetInteger(0, an, OBJPROP_WIDTH, 3);
   ObjectSetInteger(0, an, OBJPROP_ANCHOR, dir > 0 ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, an, OBJPROP_SELECTABLE, false);

   ObjectsDeleteAll(0, PFX + "trade");

   //--- v2.6: shaded risk/reward boxes (BACK=true keeps candles on top)
   if(InpShowRRBoxes)
     {
      datetime tEnd = t1 + (datetime)PeriodSeconds() * InpRRBoxBars;
      DrawRRBox(PFX + "trade_slbox", t1, entry, tEnd, sl, clrLightPink,      clrOrangeRed);
      DrawRRBox(PFX + "trade_tpbox", t1, entry, tEnd, tp, clrPaleTurquoise, clrTeal);
     }

   TradeLine(PFX + "trade_e", t1, entry, clrGold,      "Entry " + Pr(entry));
   TradeLine(PFX + "trade_s", t1, sl,    clrOrangeRed, "SL "    + Pr(sl));
   TradeLine(PFX + "trade_t", t1, tp,    clrLimeGreen, "TP "    + Pr(tp));

   double risk = MathAbs(entry - sl);
   double rr   = risk > 0 ? MathAbs(tp - entry) / risk : 0;

   g_lastSetup = StringFormat("%s %s | RR 1:%.1f | %.0f%%",
                              dir > 0 ? "BUY" : "SELL", pattern, rr, score);
   string msg = StringFormat("StillaEdge [%s %s] %s @%s SL %s TP %s RR 1:%.1f score %.0f%% (bounce %.0f%%, %s)",
                             _Symbol, EnumToString(_Period),
                             dir > 0 ? "BUY" : "SELL", Pr(entry), Pr(sl), Pr(tp),
                             rr, score, g_z[zi].BounceRate(), pattern);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   SendWebhook("setup", dir > 0 ? "BUY" : "SELL", entry, sl, tp, score);

   //--- v2.5: register for outcome tracking
   if(InpTrackOutcomes)
     {
      int n = ArraySize(g_openSetups);
      ArrayResize(g_openSetups, n + 1);
      g_openSetups[n].t0    = t1;
      g_openSetups[n].dir   = dir;
      g_openSetups[n].entry = entry;
      g_openSetups[n].sl    = sl;
      g_openSetups[n].tp    = tp;
      g_openSetups[n].score = score;
      LogCSV(StringFormat("%s,OPEN,%s,%s,%s,%s,%s,%.0f",
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol,
             dir > 0 ? "BUY" : "SELL", Pr(entry), Pr(sl), Pr(tp), score));
     }
   DrawDashboard();
  }

//+------------------------------------------------------------------+
//| v2.6: filled box rendered BEHIND candles (BACK=true), so the      |
//| opaque MT5 fill never hides price action.                         |
//+------------------------------------------------------------------+
void DrawRRBox(const string name, const datetime t1, const double p1,
               const datetime t2, const double p2,
               const color fillCol, const color borderCol)
  {
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fillCol);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);          // behind candles
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   string bn = name + "_b";                                // thin border on top
   ObjectCreate(0, bn, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, bn, OBJPROP_COLOR, borderCol);
   ObjectSetInteger(0, bn, OBJPROP_FILL, false);
   ObjectSetInteger(0, bn, OBJPROP_BACK, true);
   ObjectSetInteger(0, bn, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, bn, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, bn, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
void TradeLine(const string name, const datetime t, const double price,
               const color col, const string label)
  {
   ObjectCreate(0, name, OBJ_TREND, 0, t, price, TimeCurrent() + PeriodSeconds() * 20, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   string ln = name + "_l";
   ObjectCreate(0, ln, OBJ_TEXT, 0, t, price);
   ObjectSetString(0, ln, OBJPROP_TEXT, label);
   ObjectSetInteger(0, ln, OBJPROP_COLOR, col);
   ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
   ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| v2.5: check every open setup against live Bid — first of TP/SL   |
//| touched decides the outcome. Removes closed setups from memory.  |
//+------------------------------------------------------------------+
void CheckOutcomes()
  {
   int n = ArraySize(g_openSetups);
   if(n == 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   for(int i = n - 1; i >= 0; i--)
     {
      int res = 0;
      if(g_openSetups[i].dir > 0)
        {
         if(bid <= g_openSetups[i].sl)      res = -1;
         else if(bid >= g_openSetups[i].tp) res = +1;
        }
      else
        {
         if(bid >= g_openSetups[i].sl)      res = -1;
         else if(bid <= g_openSetups[i].tp) res = +1;
        }
      if(res == 0) continue;

      double risk = MathAbs(g_openSetups[i].entry - g_openSetups[i].sl);
      double rMul = 0;
      if(risk > 0)
         rMul = (res > 0) ? MathAbs(g_openSetups[i].tp - g_openSetups[i].entry) / risk : -1.0;
      string side   = g_openSetups[i].dir > 0 ? "BUY" : "SELL";
      string result = res > 0 ? "WIN" : "LOSS";
      int    holdMin = (int)((TimeCurrent() - g_openSetups[i].t0) / 60);

      if(res > 0) { g_winsToday++; g_winsTotal++; }
      else        { g_lossToday++; g_lossTotal++; }

      string msg = StringFormat("StillaEdge [%s] %s setup @%s -> %s (%.1fR, %d min, score %.0f%%)",
                                _Symbol, side, Pr(g_openSetups[i].entry),
                                result, rMul, holdMin, g_openSetups[i].score);
      Print(msg);
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(msg);
      SendWebhookOutcome(side, result, g_openSetups[i].entry, bid, rMul,
                         g_openSetups[i].score, holdMin);
      LogCSV(StringFormat("%s,%s,%s,%s,%s,%s,%.1f,%d",
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), result, _Symbol,
             side, Pr(g_openSetups[i].entry), Pr(bid), rMul, holdMin));

      for(int j = i; j < ArraySize(g_openSetups) - 1; j++)
         g_openSetups[j] = g_openSetups[j + 1];
      ArrayResize(g_openSetups, ArraySize(g_openSetups) - 1);
      DrawDashboard();
     }
  }

//+------------------------------------------------------------------+
//| v2.5: daily summary at InpReportHour (server time), once per day  |
//+------------------------------------------------------------------+
void CheckDailyReport()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   //--- reset daily counters when the calendar day changes
   if(dt.day != g_counterDay)
     {
      if(g_counterDay != -1) { g_winsToday = 0; g_lossToday = 0; }
      g_counterDay = dt.day;
     }

   if(dt.hour < InpReportHour || dt.day == g_lastReportDay) return;
   g_lastReportDay = dt.day;

   int    closed = g_winsToday + g_lossToday;
   double wr     = closed > 0 ? 100.0 * g_winsToday / closed : 0.0;
   string msg = StringFormat("StillaEdge Daily Report [%s %s] closed %d | WIN %d / LOSS %d | winrate %.0f%% | still open %d | since attach: %dW/%dL",
                             _Symbol, EnumToString(_Period), closed,
                             g_winsToday, g_lossToday, wr,
                             ArraySize(g_openSetups), g_winsTotal, g_lossTotal);
   Print(msg);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   SendWebhookReport(closed, g_winsToday, g_lossToday, wr, ArraySize(g_openSetups));
   LogCSV(StringFormat("%s,REPORT,%s,%d,%d,%d,%.0f,%d",
          TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol,
          closed, g_winsToday, g_lossToday, wr, ArraySize(g_openSetups)));
  }

//+------------------------------------------------------------------+
void LogCSV(const string line)
  {
   if(!InpLogToCSV) return;
   int h = FileOpen("StillaEdge_journal.csv",
                    FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
   if(h == INVALID_HANDLE) { Print("StillaEdge: journal file open failed ", GetLastError()); return; }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\n");
   FileClose(h);
  }

//+------------------------------------------------------------------+
void SendWebhookOutcome(const string side, const string result,
                        const double entry, const double exitPx, const double rMul,
                        const double score, const int holdMin)
  {
   if(StringLen(InpWebhookURL) == 0) return;
   string json = StringFormat(
      "{\"kind\":\"outcome\",\"symbol\":\"%s\",\"tf\":\"%s\",\"side\":\"%s\","
      "\"result\":\"%s\",\"entry\":%s,\"exit\":%s,\"r\":%.1f,\"score\":%.0f,"
      "\"hold_min\":%d,\"time\":\"%s\"}",
      _Symbol, EnumToString(_Period), side, result, Pr(entry), Pr(exitPx),
      rMul, score, holdMin,
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   PostJson(json);
  }

//+------------------------------------------------------------------+
void SendWebhookReport(const int closed, const int wins, const int losses,
                       const double winrate, const int openCnt)
  {
   if(StringLen(InpWebhookURL) == 0) return;
   string json = StringFormat(
      "{\"kind\":\"report\",\"symbol\":\"%s\",\"tf\":\"%s\",\"closed\":%d,"
      "\"wins\":%d,\"losses\":%d,\"winrate\":%.0f,\"open\":%d,"
      "\"total_wins\":%d,\"total_losses\":%d,\"time\":\"%s\"}",
      _Symbol, EnumToString(_Period), closed, wins, losses, winrate, openCnt,
      g_winsTotal, g_lossTotal,
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   PostJson(json);
  }

//+------------------------------------------------------------------+
//| Webhook: legal in EA context. Runs in EA's own thread — the       |
//| chart UI never freezes. Hard 5s timeout; failures only log.       |
//| MT5: Tools > Options > Expert Advisors > Allow WebRequest URL.    |
//+------------------------------------------------------------------+
void SendWebhook(const string kind, const string side, const double entry,
                 const double sl, const double tp, const double score)
  {
   if(StringLen(InpWebhookURL) == 0) return;

   string json = StringFormat(
      "{\"kind\":\"%s\",\"symbol\":\"%s\",\"tf\":\"%s\",\"side\":\"%s\","
      "\"entry\":%s,\"sl\":%s,\"tp\":%s,\"score\":%.0f,\"time\":\"%s\"}",
      kind, _Symbol, EnumToString(_Period), side,
      Pr(entry), Pr(sl), Pr(tp), score,
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   PostJson(json);
  }

//+------------------------------------------------------------------+
//| v2.7: nearest N zones above/below price as a JSON array           |
//+------------------------------------------------------------------+
string ZonesJson(const bool above, const double px, const int maxN)
  {
   string out = "";
   int total = ArraySize(g_z);
   if(total == 0) return out;
   bool used[];
   ArrayResize(used, total);
   ArrayInitialize(used, false);

   for(int k = 0; k < maxN; k++)
     {
      int best = -1;
      double bd = DBL_MAX;
      for(int z = 0; z < total; z++)
        {
         if(used[z]) continue;
         double mid = (g_z[z].top + g_z[z].bottom) / 2.0;
         if(above  && mid <= px) continue;
         if(!above && mid >= px) continue;
         double d = MathAbs(mid - px);
         if(d < bd) { bd = d; best = z; }
        }
      if(best < 0) break;
      used[best] = true;
      if(StringLen(out) > 0) out += ",";
      out += StringFormat("{\"tf\":\"%s\",\"lo\":%s,\"hi\":%s,\"touches\":%d,\"bounce\":%.0f,\"confluence\":%s}",
                          g_tfn[g_z[best].tf], Pr(g_z[best].bottom), Pr(g_z[best].top),
                          g_z[best].touches, g_z[best].BounceRate(),
                          g_z[best].conf ? "true" : "false");
     }
   return out;
  }

//+------------------------------------------------------------------+
//| v2.7: periodic market snapshot -> n8n -> Gemini analysis          |
//+------------------------------------------------------------------+
void CheckSnapshot()
  {
   if(!InpSnapshotOn || StringLen(InpWebhookURL) == 0) return;
   if(g_atrNow <= 0 || ArraySize(g_z) == 0) return;        // wait for first bar pass
   if(TimeCurrent() - g_lastSnapTime < (datetime)InpSnapshotHours * 3600) return;
   g_lastSnapTime = TimeCurrent();

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    ad  = AlignmentDir();

   string json = StringFormat(
      "{\"kind\":\"snapshot\",\"symbol\":\"%s\",\"tf\":\"%s\",\"price\":%s,\"atr\":%s,"
      "\"trend_1d\":\"%s\",\"trend_4h\":\"%s\",\"trend_1h\":\"%s\","
      "\"momo_30m\":\"%s\",\"momo_15m\":\"%s\",\"alignment\":\"%s\","
      "\"resistance\":[%s],\"support\":[%s],\"time\":\"%s\"}",
      _Symbol, EnumToString(_Period), Pr(bid), Pr(g_atrNow),
      DirTxt(g_trend[4]), DirTxt(g_trend[3]), DirTxt(g_trend[2]),
      DirTxt(g_mom[1]), DirTxt(g_mom[0]),
      ad > 0 ? "BULL" : (ad < 0 ? "BEAR" : "MIXED"),
      ZonesJson(true, bid, 3), ZonesJson(false, bid, 3),
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   PostJson(json);
   Print("StillaEdge: snapshot sent");
  }

//+------------------------------------------------------------------+
//| v2.7: once-daily economic calendar digest (times pre-converted    |
//| to Myanmar time). Enable on ONE chart only to avoid duplicates.   |
//+------------------------------------------------------------------+
void CheckCalendarDigest()
  {
   if(!InpCalendarOn || StringLen(InpWebhookURL) == 0) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpCalendarHour || dt.day == g_lastCalendarDay) return;
   g_lastCalendarDay = dt.day;

   datetime dayStart = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   datetime dayEnd   = dayStart + 86400;

   MqlCalendarValue vals[];
   int n = CalendarValueHistory(vals, dayStart, dayEnd);
   if(n <= 0)
     {
      Print("StillaEdge: calendar unavailable, err ", GetLastError());
      return;
     }

   int srvOff = (int)(TimeTradeServer() - TimeGMT());     // server -> GMT
   string ev = "";
   int cnt = 0;
   for(int i = 0; i < n && cnt < 20; i++)
     {
      MqlCalendarEvent e;
      if(!CalendarEventById(vals[i].event_id, e)) continue;
      if(e.importance < CALENDAR_IMPORTANCE_MODERATE) continue;
      MqlCalendarCountry c;
      if(!CalendarCountryById(e.country_id, c)) continue;

      datetime mmTime = vals[i].time - srvOff + 23400;    // GMT + 6h30m Yangon
      string name = e.name;
      StringReplace(name, "\"", "'");
      if(StringLen(ev) > 0) ev += ",";
      ev += StringFormat("{\"time_mm\":\"%s\",\"currency\":\"%s\",\"importance\":\"%s\",\"event\":\"%s\"}",
                         TimeToString(mmTime, TIME_MINUTES), c.currency,
                         e.importance == CALENDAR_IMPORTANCE_HIGH ? "HIGH" : "MODERATE", name);
      cnt++;
     }
   if(cnt == 0) return;

   string json = StringFormat(
      "{\"kind\":\"calendar\",\"date\":\"%s\",\"timezone\":\"Asia/Yangon\",\"events\":[%s]}",
      TimeToString(TimeCurrent(), TIME_DATE), ev);
   PostJson(json);
   Print("StillaEdge: calendar digest sent (", cnt, " events)");
  }

//+------------------------------------------------------------------+
void PostJson(const string json)
  {
   char data[], result[];
   StringToCharArray(json, data, 0, StringLen(json), CP_UTF8);
   string headers = "Content-Type: application/json\r\n";
   string rh;
   ResetLastError();
   int code = WebRequest("POST", InpWebhookURL, headers, 5000, data, result, rh);
   if(code == -1)
      Print("StillaEdge webhook failed, err ", GetLastError(),
            " — check URL whitelist in Tools>Options>Expert Advisors");
   else if(code >= 300)
      Print("StillaEdge webhook HTTP ", code);
  }

//+------------------------------------------------------------------+
string Pr(const double p) { return DoubleToString(p, _Digits); }
//+------------------------------------------------------------------+
