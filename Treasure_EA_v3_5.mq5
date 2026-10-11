//+------------------------------------------------------------------+
//|       TREASURE EA v3.5 (H1 Trend + M5 Sweep/FVG + M1 Retracement)   |
//|                                                                  |
//| v3.31 speed changes: adaptive HTF history + 30-second fallback. |
//|  - H4/H1 bias, liquidity and exec-TF scans use adaptive history. |
//|    If full history is unavailable after the short warm-up, the EA |
//|    falls back to a smaller, still-usable history sample.         |
//|  - Liquidity scans use the same fallback, avoiding a hidden      |
//|    fixed-150-bar bottleneck that could keep the EA waiting.       |
//|  - Scan size reduced to 150 bars and the dashboard timer slowed   |
//|    to 500 ms to reduce needless chart redraw overhead.            |
//|  - Removed the daily trade-count cap; core SMC confirmations stay. |
//|  - A one-time alert fires if it ever falls back, since signals   |
//|    on thinner history are less reliable until full history       |
//|    backfills in the background.                                  |
//|  - The dashboard/status line shows a live countdown while        |
//|    waiting, so it's visible rather than a silent stall.          |
//+------------------------------------------------------------------+
//|                                                                  |
//| v3.2 adds, on top of v3.1's speed changes:                       |
//|  - Default exec timeframe M5 -> M1 (true scalp speed; M1..H1     |
//|    still selectable)                                             |
//|  - Break-even moved up to +0.5R (was +1R): protects a scalp      |
//|    trade almost immediately instead of letting it round-trip     |
//|  - Partial close now ON by default at +1R, banking 50% of the    |
//|    position quickly instead of holding the whole size for the    |
//|    full target                                                   |
//|  - Min/fallback R:R 1.5 -> 1.2: shorter, faster-hit targets,      |
//|    matching scalp-style quick in/out rather than a long runner   |
//+------------------------------------------------------------------+
//|                                                                  |
//| Core setup sequence enforced per direction (bull shown):              |
//|  1. HTF bias    : H1 + M30 fractal structure agreement                     |
//|  2. Kill zone   : London / NY AM / NY PM (New York time)         |
//|  3. Sweep       : sell-side liquidity taken (swing lows, equal   |
//|                   lows, PDL, Asian low) with close back above    |
//|  4. MSS         : DISPLACEMENT candle closes above the last      |
//|                   swing high that preceded the sweep             |
//|  5. Entry array : FVG formed in the displacement leg -   |
//|                   LIMIT order at consequent encroachment after M1 confirmation, OR a   |
//|                   MARKET order if price is already inside the    |
//|                   zone when the setup completes (v3.1, see #6)   |
//|  6. Optional premium/discount filter (off by default)             |
//|  7. SL beyond the sweep low | TP at opposing liquidity (>= RR)   |
//|  8. Management  : break-even / optional partial                  |
//| Bear setups run through the same code on mirrored prices.        |
//|                                                                  |
//| v3.1 changes (speed / frequency, same sequence, nothing removed):|
//|  1. Scalper-style market fallback: v3.0 discarded any setup      |
//|     where price had already reached the FVG/OB zone (a resting  |
//|     limit order can't be placed behind the market). v3.1 takes   |
//|     the trade at market instead of throwing the signal away.     |
//|  2. Execution timeframe default M15 -> M5: faster sweep/MSS      |
//|     detection, more setups per day.                              |
//|  3. Kill zones widened (still excludes the dead Asian session)   |
//|     and NY PM turned on by default, so most of the liquid day    |
//|     is tradeable instead of ~6 hours.                            |
//|  4. H1/H4 double-agreement no longer required by default -       |
//|     H4 bias alone is enough (toggle input, unchanged either way).|
//|  5. Min R:R 2.0 -> 1.5, and a 1.5R fallback target is now on by  |
//|     default so a setup with no liquidity target past 1.5R isn't  |
//|     skipped outright.                                            |
//|  6. Gold-scale spread/SL caps (old values were forex-pip sized   |
//|     and rejected most gold setups outright).                     |
//|  7. More trades/day allowed, pending orders expire sooner so a   |
//|     stale setup is replaced by a fresh one faster.                |
//|  8. Popup + push alert fires on every executed trade.             |
//+------------------------------------------------------------------+
#property version   "3.50"
#property description "Treasure EA v3.5 - H1 bias, M5 sweep/displacement/FVG, M1 retracement confirmation"

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_ZONE_MODE
{
   ZONE_FVG_THEN_OB = 0,   // FVG first, fall back to OB
   ZONE_FVG_ONLY    = 1,   // FVG only
   ZONE_OB_ONLY     = 2    // Order block only
};

//============================== INPUTS ==============================//
input group "Trade"
input double InpRiskPercent           = 0.25;   // Risk per trade, % of equity (0 = fixed lots)
input double InpLots                  = 0.01;   // Fixed lots (used only when Risk % = 0)
input long   InpMagicNumber           = 31001;
input int    InpMaxActive             = 1;      // One active position/order at a time
input int    InpSLBufferPoints        = 50;     // SL buffer beyond the sweep extreme (gold-scale)
input int    InpMaxSLPoints           = 4000;   // Reject setups with wider SL (0 = off)
input int    InpTPBufferPoints        = 10;     // TP placed this far before the liquidity

input group "Targets and orders"
input double InpMinRR                 = 2.0;    // Minimum reward:risk target
input double InpFallbackRR            = 2.0;    // If no target >= MinRR: fixed RR (0 = skip trade)
input int    InpOrderExpiryBars       = 8;      // Cancel unfilled limit after N exec-TF bars

input group "Trade management"
input double InpBreakEvenAtR          = 0.0;    // Disabled for clean baseline testing (0 = off)
input int    InpBEBufferPoints        = 10;
input double InpPartialAtR            = 0.0;    // Disabled for clean baseline testing (0 = off)
input double InpPartialPercent        = 50.0;

input group "Limits"
input double InpMaxDailyLossR         = 2.0;    // Stop opening trades after 2R daily loss (0 = off)
input int    InpMaxSpreadPoints       = 300;    // Gold-scale spread cap

input group "Kill zones (New York time)"
input bool   InpUseKillZones          = false;  // Disabled by default for a clean baseline test
input int    InpServerToNYHours       = 7;      // NY time = broker server time - this (7 for GMT+2/+3 brokers)
input bool   InpKZLondon              = true;
input int    InpLondonStart           = 2;
input int    InpLondonEnd             = 9;
input bool   InpKZNewYorkAM           = true;
input int    InpNYAMStart             = 7;
input int    InpNYAMEnd               = 12;
input bool   InpKZNewYorkPM           = true;   // now on by default
input int    InpNYPMStart             = 12;
input int    InpNYPMEnd               = 17;

input group "Warm-up"
input int    InpMaxWarmupSeconds      = 30;     // Max wait for full history before using sufficient reduced history

input group "Structure (ICT model)"
input ENUM_TIMEFRAMES InpExecTF       = PERIOD_M5;   // Setup timeframe; M1 candle confirms execution
input int    InpFractalLen            = 2;      // Swing fractal strength, exec TF
input int    InpHtfFractalLen         = 2;      // Swing fractal strength, H1/M30
input int    InpScanBars              = 150;    // Leaner scan for faster per-bar analysis
input int    InpSetupMaxAgeBars       = 30;     // Sweep must be no older than this
input int    InpMaxSweepToMSSBars     = 20;     // Max bars from sweep to MSS
input int    InpMSSLookback           = 30;     // Swing high to break must be within this many bars before sweep
input double InpDispBodyATR           = 0.8;    // MSS candle body >= this x ATR(14)
input double InpMinFVGATR             = 0.15;   // Min FVG size in ATR
input ENUM_ZONE_MODE InpZoneMode      = ZONE_FVG_ONLY;  // Core strategy uses FVG only; other modes retained for old presets
input double InpEntryPct              = 50.0;   // Entry depth in zone: 0 = proximal edge, 50 = CE, 100 = distal
input bool   InpRequirePD             = false;  // Disabled: trend + sweep + FVG baseline
input bool   InpUseBias               = true;   // Require H1 directional bias only
input bool   InpRequireH1Agree        = true;   // Retained for preset compatibility; H1 bias is active
input bool   InpUsePDHL               = true;   // Previous-day high/low as potential sweep levels
input bool   InpUseAsia               = false;  // Keep baseline sweep scan lean; use swing liquidity + PDH/PDL

input group "Alerts"
input bool   InpAlertOnTrade          = true;   // popup + push notification on executed trade

input group "AI HUD"
input bool   InpShowDashboard         = true;   // Sci-fi HUD panel
input int    InpPanelX                = 15;     // Panel X (pixels from left)
input int    InpPanelY                = 30;     // Panel Y (pixels from top)
input bool   InpDrawZones             = true;   // Draw sweep / MSS / zone overlays
input bool   InpDrawTradeLines        = true;   // Draw entry / SL / TP lines
input bool   InpApplyChartTheme       = true;   // Dark neon chart theme

//============================== HUD CONSTANTS =======================//
#define HUD       "TRS_"
#define HUD_W     370
#define HUD_H     612

#define C_CYAN    C'0,238,255'
#define C_GREEN   C'0,255,150'
#define C_RED     C'255,50,90'
#define C_AMBER   C'255,176,0'
#define C_TEXT    C'170,205,220'
#define C_DIM     C'100,140,160'
#define C_OFF     C'20,38,52'
#define C_RULE    C'0,70,100'

//============================== TYPES ===============================//
struct Lvl
{
   double   p;
   datetime t;
};

struct Setup
{
   bool     valid;          // stage 5: complete, ready to place
   int      stage;          // 0 none,1 sweep,2 MSS,3 zone,4 premium/discount,5 target
   bool     isFVG;
   datetime key;            // sweep bar time = unique setup id
   double   entry;
   double   sl;
   double   tp;
   double   rr;
   double   zoneLo;
   double   zoneHi;
   datetime zoneT;
   double   sweepLevel;
   double   sweepExtreme;
   datetime sweepT;
   double   mssLevel;
   datetime mssT;
   datetime mssFromT;
};

//============================== GLOBALS =============================//
string   g_lastSignal = "NONE";
string   g_status     = "STARTING";
string   g_reason     = "";

Lvl      g_sweepLows[];      // sell-side liquidity (potential sweeps for longs)
Lvl      g_sweepHighs[];     // buy-side liquidity  (potential sweeps for shorts)
Lvl      g_tgtHighs[];       // intact buy-side liquidity  (long targets)
Lvl      g_tgtLows[];        // intact sell-side liquidity (short targets)

Setup    g_bull;
Setup    g_bear;
string   g_noteBull = "";
string   g_noteBear = "";
bool     g_biasBull = false;
bool     g_biasBear = false;
bool     g_inKZ     = false;
double   g_eq       = 0.0;
bool     g_eqValid  = false;

datetime g_usedKeyBull = 0;
datetime g_usedKeyBear = 0;

bool     g_execReady = false;
datetime g_lastExec  = 0;
datetime g_lastH1Bar = 0;
int      g_cachedH1Bias = 0;

// v3.3 warm-up: timestamp the EA was attached, so history requirements
// can relax if the broker hasn't delivered full HTF history in time.
ulong    g_initMs        = 0;
bool     g_reducedHistory = false;
bool     g_reducedNotified = false;

// HUD state
int      g_px = 15;
int      g_py = 30;
ulong    g_tick = 0;
double   g_dayPL = 0.0;
int      g_dayEntries = 0;

// Chart theme save / restore
int      g_themeIds[8] = {CHART_COLOR_BACKGROUND, CHART_COLOR_FOREGROUND, CHART_COLOR_GRID,
                          CHART_COLOR_CHART_UP, CHART_COLOR_CHART_DOWN, CHART_COLOR_CHART_LINE,
                          CHART_COLOR_CANDLE_BULL, CHART_COLOR_CANDLE_BEAR};
long     g_themeSaved[8];
bool     g_themeOn = false;
long     g_descrSaved = 0;
bool     g_descrChanged = false;

//============================== HELPERS ==============================//
double PointValue()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double NormalizePrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

bool HudActive()
{
   // No chart objects in a non-visual backtest.
   return !(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE));
}

bool GetRates(ENUM_TIMEFRAMES tf, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 0, count, rates);
   return copied >= count;
}

// v3.3: tries the full bar count first (best quality). If that's not
// available yet AND the warm-up budget (default 5 min since attach) has
// run out, falls back to a smaller count so the EA can start working
// with whatever history the broker has actually delivered, instead of
// sitting on "Waiting for chart history" indefinitely. minCount is the
// floor below which the data is too thin to trust at all.
bool GetRatesAdaptive(ENUM_TIMEFRAMES tf, int fullCount, int minCount, MqlRates &rates[])
{
   if(GetRates(tf, fullCount, rates))
      return true;

   bool warmupOver = (GetTickCount() - g_initMs) > (ulong)(InpMaxWarmupSeconds * 1000);
   if(!warmupOver) return false;

   int reduced = MathMax(minCount, fullCount / 3);
   if(GetRates(tf, reduced, rates))
   {
      g_reducedHistory = true;
      return true;
   }
   return false;
}

bool SpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = PointValue();
   if(point <= 0) return false;
   return ((ask - bid) / point) <= InpMaxSpreadPoints;
}

int CountMyPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         n++;
   }
   return n;
}

int CountMyPendings()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      long t = OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT) n++;
   }
   return n;
}

// Which directions currently have an open position or live pending order.
void ActiveDirs(bool &hasBuy, bool &hasSell)
{
   hasBuy = false;
   hasSell = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) hasBuy = true;
      else hasSell = true;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      long t = OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_LIMIT) hasBuy = true;
      if(t == ORDER_TYPE_SELL_LIMIT) hasSell = true;
   }
}

double FloatingPL()
{
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

// Realised P/L (incl. commission, swap, fees) and filled-entry count for
// today (broker server day), for deals carrying this EA's magic number.
bool TodayStats(double &pl, int &entries)
{
   pl = 0.0;
   entries = 0;

   MqlDateTime d;
   TimeToStruct(TimeCurrent(), d);
   d.hour = 0;
   d.min  = 0;
   d.sec  = 0;
   datetime from = StructToTime(d);

   if(!HistorySelect(from, TimeCurrent() + 60)) return false;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != InpMagicNumber) continue;

      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

      if(HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN) entries++;

      pl += HistoryDealGetDouble(tk, DEAL_PROFIT)
          + HistoryDealGetDouble(tk, DEAL_SWAP)
          + HistoryDealGetDouble(tk, DEAL_COMMISSION)
          + HistoryDealGetDouble(tk, DEAL_FEE);
   }
   return true;
}

//========================== VOLUME HELPERS ==========================//
int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int d = 0;
   while(d < 8 && MathAbs(step - MathRound(step)) > 1e-9)
   {
      step *= 10.0;
      d++;
   }
   return d;
}

// riskMode = true : below-minimum volume returns 0 (never silently raised)
// riskMode = false: fixed lots are clamped into [min, max]
double NormalizeVolume(double v, bool riskMode)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0 || vmin <= 0) return 0.0;

   v = MathFloor(v / step + 1e-9) * step;
   if(v > vmax) v = vmax;
   if(v < vmin)
   {
      if(riskMode) return 0.0;
      v = vmin;
   }
   return NormalizeDouble(v, VolumeDigits());
}

double CalcLots(bool buy, double entry, double sl)
{
   if(InpRiskPercent <= 0)
      return NormalizeVolume(InpLots, false);

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   double p = 0.0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                       _Symbol, 1.0, entry, sl, p) || p == 0.0)
   {
      g_reason = "Cannot calculate risk per lot";
      return 0.0;
   }

   double lots = NormalizeVolume(riskMoney / MathAbs(p), true);
   if(lots <= 0.0)
      g_reason = "Risk % too small for minimum lot";
   return lots;
}

//============================ TIME / KILL ZONES =====================//
int NYHourOf(datetime t)
{
   MqlDateTime d;
   TimeToStruct(t - (datetime)(InpServerToNYHours * 3600), d);
   return d.hour;
}

bool InKillZone()
{
   if(!InpUseKillZones) return true;

   int h = NYHourOf(TimeCurrent());
   if(InpKZLondon    && h >= InpLondonStart && h < InpLondonEnd) return true;
   if(InpKZNewYorkAM && h >= InpNYAMStart   && h < InpNYAMEnd)   return true;
   if(InpKZNewYorkPM && h >= InpNYPMStart   && h < InpNYPMEnd)   return true;
   return false;
}

//========================= STRUCTURE PRIMITIVES =====================//
void ResetSetup(Setup &s)
{
   ZeroMemory(s);
}

// Mirrors prices (p -> -p, high/low swapped) so one bullish algorithm can
// detect bearish setups. The array keeps series orientation.
void MirrorRates(const MqlRates &src[], MqlRates &dst[], bool mirror)
{
   int n = ArraySize(src);
   ArrayResize(dst, n);
   ArraySetAsSeries(dst, true);
   for(int i = 0; i < n; i++)
   {
      dst[i] = src[i];
      if(mirror)
      {
         dst[i].open  = -src[i].open;
         dst[i].close = -src[i].close;
         dst[i].high  = -src[i].low;
         dst[i].low   = -src[i].high;
      }
   }
}

// Confirmed fractal swings. Indices are returned ascending (most recent
// first). A swing at i needs L closed bars on each side.
void CollectSwings(const MqlRates &r[], int L, bool highs, int &out[])
{
   ArrayResize(out, 0);
   int n = ArraySize(r);
   for(int i = L + 1; i < n - L; i++)
   {
      bool ok = true;
      for(int k = 1; k <= L && ok; k++)
      {
         if(highs)
         {
            if(!(r[i].high > r[i + k].high && r[i].high >= r[i - k].high)) ok = false;
         }
         else
         {
            if(!(r[i].low < r[i + k].low && r[i].low <= r[i - k].low)) ok = false;
         }
      }
      if(ok)
      {
         int m = ArraySize(out);
         ArrayResize(out, m + 1);
         out[m] = i;
      }
   }
}

double ATRValue(const MqlRates &r[], int period)
{
   int n = ArraySize(r);
   if(n < period + 3) return 0.0;

   double sum = 0.0;
   for(int i = 1; i <= period; i++)
   {
      double tr = r[i].high - r[i].low;
      tr = MathMax(tr, MathAbs(r[i].high - r[i + 1].close));
      tr = MathMax(tr, MathAbs(r[i].low  - r[i + 1].close));
      sum += tr;
   }
   return sum / period;
}

// True if any bar NEWER than time t (including the forming bar) took the level.
bool ExceededSince(const MqlRates &r[], double price, datetime t, bool isHigh)
{
   int n = ArraySize(r);
   for(int k = 0; k < n && r[k].time > t; k++)
   {
      if(isHigh) { if(r[k].high > price) return true; }
      else       { if(r[k].low  < price) return true; }
   }
   return false;
}

// 1 = bullish (HH + HL), -1 = bearish (LH + LL), 0 = neutral.
bool HtfBias(ENUM_TIMEFRAMES tf, int &bias)
{
   bias = 0;
   MqlRates r[];
   if(!GetRatesAdaptive(tf, 150, 40, r)) return false;

   int sh[], sl[];
   CollectSwings(r, InpHtfFractalLen, true,  sh);
   CollectSwings(r, InpHtfFractalLen, false, sl);
   if(ArraySize(sh) < 2 || ArraySize(sl) < 2) return true;

   bool hh = r[sh[0]].high > r[sh[1]].high;
   bool lh = r[sh[0]].high < r[sh[1]].high;
   bool hl = r[sl[0]].low  > r[sl[1]].low;
   bool ll = r[sl[0]].low  < r[sl[1]].low;

   if(hh && hl) bias = 1;
   else if(lh && ll) bias = -1;
   return true;
}

// H1 dealing range = most recent confirmed swing high and swing low.
bool DealingRange(double &hi, double &lo)
{
   MqlRates r[];
   if(!GetRatesAdaptive(PERIOD_H1, 150, 40, r)) return false;

   int sh[], sl[];
   CollectSwings(r, InpHtfFractalLen, true,  sh);
   CollectSwings(r, InpHtfFractalLen, false, sl);
   if(ArraySize(sh) < 1 || ArraySize(sl) < 1) return false;

   hi = r[sh[0]].high;
   lo = r[sl[0]].low;
   return hi > lo;
}

//============================== LIQUIDITY ===========================//
void AddLvl(Lvl &arr[], double p, datetime t)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].p = p;
   arr[n].t = t;
}

// Builds sweep levels (exec swings, H1 swings, PDH/PDL, Asian range) and
// intact liquidity targets (exec / H1 / H4 swings, PDH/PDL, Asian range).
bool BuildLiquidity(const MqlRates &r[])
{
   ArrayResize(g_sweepLows, 0);
   ArrayResize(g_sweepHighs, 0);
   ArrayResize(g_tgtHighs, 0);
   ArrayResize(g_tgtLows, 0);

   int n = ArraySize(r);
   if(n < 60) return false;
   datetime winStart = r[n - 1].time;

   int sh[], sl[];

   // Exec-TF swings (also covers equal highs / lows as separate levels).
   CollectSwings(r, InpFractalLen, true,  sh);
   CollectSwings(r, InpFractalLen, false, sl);
   for(int q = 0; q < ArraySize(sh); q++)
   {
      int k = sh[q];
      AddLvl(g_sweepHighs, r[k].high, r[k].time);
      if(!ExceededSince(r, r[k].high, r[k].time, true))
         AddLvl(g_tgtHighs, r[k].high, r[k].time);
   }
   for(int q = 0; q < ArraySize(sl); q++)
   {
      int k = sl[q];
      AddLvl(g_sweepLows, r[k].low, r[k].time);
      if(!ExceededSince(r, r[k].low, r[k].time, false))
         AddLvl(g_tgtLows, r[k].low, r[k].time);
   }

   // H1 (sweep levels + targets) and H4 (targets only).
   MqlRates h[];
   for(int pass = 0; pass < 2; pass++)
   {
      ENUM_TIMEFRAMES tf = (pass == 0) ? PERIOD_H1 : PERIOD_H4;
      // Use the same adaptive history path as bias/exec scans; otherwise
      // this fixed 150-bar request could keep the EA WAITING after fallback.
      if(!GetRatesAdaptive(tf, 150, 40, h)) return false;

      CollectSwings(h, InpHtfFractalLen, true,  sh);
      CollectSwings(h, InpHtfFractalLen, false, sl);

      for(int q = 0; q < ArraySize(sh); q++)
      {
         int k = sh[q];
         if(pass == 0 && h[k].time >= winStart)
            AddLvl(g_sweepHighs, h[k].high, h[k].time);
         if(!ExceededSince(h, h[k].high, h[k].time, true))
            AddLvl(g_tgtHighs, h[k].high, h[k].time);
      }
      for(int q = 0; q < ArraySize(sl); q++)
      {
         int k = sl[q];
         if(pass == 0 && h[k].time >= winStart)
            AddLvl(g_sweepLows, h[k].low, h[k].time);
         if(!ExceededSince(h, h[k].low, h[k].time, false))
            AddLvl(g_tgtLows, h[k].low, h[k].time);
      }
   }

   // Previous day high / low.
   if(InpUsePDHL)
   {
      double   pdh = iHigh(_Symbol, PERIOD_D1, 1);
      double   pdl = iLow(_Symbol, PERIOD_D1, 1);
      datetime d0  = iTime(_Symbol, PERIOD_D1, 0);
      if(pdh > 0 && pdl > 0 && d0 > 0)
      {
         datetime dt = d0 - 1;
         AddLvl(g_sweepHighs, pdh, dt);
         AddLvl(g_sweepLows,  pdl, dt);
         if(!ExceededSince(r, pdh, dt, true))  AddLvl(g_tgtHighs, pdh, dt);
         if(!ExceededSince(r, pdl, dt, false)) AddLvl(g_tgtLows,  pdl, dt);
      }
   }

   // Asian range = NY 20:00-24:00, last COMPLETED session.
   if(InpUseAsia)
   {
      int i = 1;
      while(i < n && NYHourOf(r[i].time) >= 20) i++;   // skip a session still in progress
      while(i < n && NYHourOf(r[i].time) < 20)  i++;   // back to the previous session's end
      if(i < n)
      {
         datetime tEnd = r[i].time;
         double hi = -DBL_MAX, lo = DBL_MAX;
         while(i < n && NYHourOf(r[i].time) >= 20)
         {
            hi = MathMax(hi, r[i].high);
            lo = MathMin(lo, r[i].low);
            i++;
         }
         if(hi > lo)
         {
            AddLvl(g_sweepHighs, hi, tEnd);
            AddLvl(g_sweepLows,  lo, tEnd);
            if(!ExceededSince(r, hi, tEnd, true))  AddLvl(g_tgtHighs, hi, tEnd);
            if(!ExceededSince(r, lo, tEnd, false)) AddLvl(g_tgtLows,  lo, tEnd);
         }
      }
   }
   return true;
}

//=========================== SETUP DETECTION ========================//
// All of the following work in "bull space" (bearish setups are mirrored).

// First bar after the level formed that trades through it. It is a valid
// sweep only if that bar closes back on the other side (rejection).
int FindSweepBar(const MqlRates &m[], double p, datetime t, int maxAge)
{
   int n = ArraySize(m);
   for(int i = n - 1; i >= 1; i--)
   {
      if(m[i].time <= t) continue;
      if(m[i].low < p)
      {
         if(m[i].close > p && i <= maxAge) return i;
         return -1;
      }
   }
   return -1;
}

// Walks one sweep through MSS -> zone -> premium/discount -> target.
// Returns false if the setup is dead (invalidated).
bool EvalSweep(const MqlRates &m[], const int &shB[], int s, double p, double sgn,
               double atr, bool eqValid, double eqB, double askB, double bidB,
               Setup &c, string &cn)
{
   ResetSetup(c);
   int n = ArraySize(m);
   double point   = PointValue();
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   string side    = (sgn > 0) ? "BULL" : "BEAR";
   int    dg      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // ---- stage 1: sweep
   c.stage      = 1;
   c.key        = m[s].time;
   c.sweepT     = m[s].time;
   c.sweepLevel = p;
   cn = side + ": liquidity swept @ " + DoubleToString(sgn * p, dg) + " - waiting MSS";

   // ---- stage 2: MSS with displacement
   int hIdx = -1;
   for(int q = 0; q < ArraySize(shB); q++)
      if(shB[q] > s) { hIdx = shB[q]; break; }
   if(hIdx < 0 || hIdx - s > InpMSSLookback) return true;

   double mssLevel = m[hIdx].high;
   c.mssLevel = mssLevel;
   c.mssFromT = m[hIdx].time;

   int mi = -1;
   int kmin = MathMax(1, s - InpMaxSweepToMSSBars);
   for(int k = s - 1; k >= kmin; k--)
      if(m[k].close > mssLevel) { mi = k; break; }
   if(mi < 0) return true;

   if((m[mi].close - m[mi].open) < InpDispBodyATR * atr)
   {
      cn = side + ": structure break lacks displacement";
      return true;
   }
   c.mssT = m[mi].time;

   double ext = DBL_MAX;
   int    ei  = s;
   for(int k = s; k >= mi; k--)
      if(m[k].low < ext) { ext = m[k].low; ei = k; }

   // Price traded below the sweep extreme after the MSS: setup is dead.
   for(int k = mi - 1; k >= 1; k--)
      if(m[k].low < ext) return false;
   if(bidB < ext) return false;

   c.sweepExtreme = ext;
   c.stage = 2;
   cn = side + ": displacement confirmed - looking for FVG";

   // ---- stage 3: FVG inside the displacement leg
   double   zLo = 0, zHi = 0;
   datetime zT = 0;
   bool     haveZone = false, isFVG = false;
   int      zRef = mi;

   if(InpZoneMode != ZONE_OB_ONLY)
   {
      double bestSize = 0;
      for(int i = mi; i <= ei - 1; i++)
      {
         if(i + 2 >= n) break;
         if(m[i + 2].high < m[i].low)
         {
            double size = m[i].low - m[i + 2].high;
            if(size >= InpMinFVGATR * atr && size > bestSize)
            {
               bestSize = size;
               zLo = m[i + 2].high;
               zHi = m[i].low;
               zT  = m[i + 2].time;
               zRef = i;
               haveZone = true;
               isFVG = true;
            }
         }
      }
   }

   if(!haveZone && InpZoneMode != ZONE_FVG_ONLY)
   {
      // OB = last down candle at/before the origin of the displacement.
      for(int j = ei; j <= ei + 5 && j < n - 1; j++)
      {
         if(m[j].close < m[j].open)
         {
            zLo = m[j].low;
            zHi = m[j].high;
            zT  = m[j].time;
            zRef = mi;
            haveZone = true;
            isFVG = false;
            break;
         }
      }
   }

   if(!haveZone)
   {
      cn = side + ": displacement confirmed - no valid FVG in leg";
      return true;
   }

   c.zoneLo = zLo;
   c.zoneHi = zHi;
   c.zoneT  = zT;
   c.isFVG  = isFVG;

   double entryB = zHi - (InpEntryPct / 100.0) * (zHi - zLo);

   bool touched = false;
   for(int k = zRef - 1; k >= 1; k--)
      if(m[k].low <= entryB) { touched = true; break; }
   if(touched || askB <= entryB + minDist)
   {
      cn = side + ": entry zone already mitigated";
      return true;
   }

   c.stage = 3;
   cn = side + ": zone armed - checking premium/discount";

   // ---- stage 4: premium / discount
   if(InpRequirePD && eqValid && entryB >= eqB)
   {
      cn = side + ": entry zone not in " + ((sgn > 0) ? "discount" : "premium");
      return true;
   }
   c.stage = 4;

   double slB  = ext - InpSLBufferPoints * point;
   double risk = entryB - slB;
   if(risk <= 0 || risk < minDist)
   {
      cn = side + ": SL distance invalid";
      return true;
   }
   if(InpMaxSLPoints > 0 && risk / point > InpMaxSLPoints)
   {
      cn = side + ": SL too wide (" + IntegerToString((int)(risk / point)) + " pts)";
      return true;
   }

   // ---- stage 5: liquidity target
   double tpB = 0, bestT = DBL_MAX;
   int nt = (sgn > 0) ? ArraySize(g_tgtHighs) : ArraySize(g_tgtLows);
   for(int ti = 0; ti < nt; ti++)
   {
      double t0 = sgn * ((sgn > 0) ? g_tgtHighs[ti].p : g_tgtLows[ti].p);
      if(t0 <= entryB) continue;
      double tpP = t0 - InpTPBufferPoints * point;
      if((tpP - entryB) / risk >= InpMinRR && t0 < bestT)
      {
         bestT = t0;
         tpB = tpP;
      }
   }

   if(tpB == 0)
   {
      if(InpFallbackRR > 0)
         tpB = entryB + risk * InpFallbackRR;
      else
      {
         cn = side + ": no liquidity target with enough R:R";
         return true;
      }
   }

   if((tpB - entryB) < minDist)
   {
      cn = side + ": TP inside broker stop level";
      return true;
   }

   c.entry = entryB;
   c.sl    = slB;
   c.tp    = tpB;
   c.rr    = (tpB - entryB) / risk;
   c.stage = 5;
   c.valid = true;
   cn = side + ": setup complete (RR " + DoubleToString(c.rr, 1) + ")";
   return true;
}

void ToOrig(Setup &s, bool bull)
{
   if(bull) return;
   s.sweepLevel   = -s.sweepLevel;
   s.sweepExtreme = -s.sweepExtreme;
   s.mssLevel     = -s.mssLevel;
   s.entry        = -s.entry;
   s.sl           = -s.sl;
   s.tp           = -s.tp;
   double lo = -s.zoneHi;
   double hi = -s.zoneLo;
   s.zoneLo = lo;
   s.zoneHi = hi;
}

bool FindSetup(bool bull, const MqlRates &r[], double atr, bool eqValid, double eq,
               double ask, double bid, Setup &out, string &note)
{
   ResetSetup(out);
   note = (bull ? "BULL" : "BEAR") + ": no qualifying liquidity sweep";

   int n = ArraySize(r);
   if(n < 60 || atr <= 0) return false;

   double sgn = bull ? 1.0 : -1.0;
   MqlRates m[];
   MirrorRates(r, m, !bull);

   double askB = bull ? ask : -bid;
   double bidB = bull ? bid : -ask;
   double eqB  = sgn * eq;

   int shB[];
   CollectSwings(m, InpFractalLen, true, shB);

   int ns = bull ? ArraySize(g_sweepLows) : ArraySize(g_sweepHighs);

   bool   have = false;
   Setup  best;
   ResetSetup(best);
   string bestNote = note;
   int    bestS = INT_MAX;

   for(int li = 0; li < ns; li++)
   {
      double   p  = sgn * (bull ? g_sweepLows[li].p : g_sweepHighs[li].p);
      datetime lt = bull ? g_sweepLows[li].t : g_sweepHighs[li].t;

      int s = FindSweepBar(m, p, lt, InpSetupMaxAgeBars);
      if(s < 0) continue;

      Setup  c;
      string cn = "";
      if(!EvalSweep(m, shB, s, p, sgn, atr, eqValid, eqB, askB, bidB, c, cn))
         continue;

      if(!have || c.stage > best.stage || (c.stage == best.stage && s < bestS))
      {
         best = c;
         bestNote = cn;
         bestS = s;
         have = true;
      }
   }

   if(!have) return false;

   ToOrig(best, bull);
   out  = best;
   note = bestNote;
   return true;
}

// M1 confirmation: last CLOSED M1 candle must reject/close through the
// FVG midpoint in the intended direction. This is a lightweight entry filter.
bool M1EntryConfirm(bool bull, const Setup &s)
{
   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 3, m1) < 3) return false;

   // Use completed candle [1], never the still-forming candle [0].
   double mid = (s.zoneLo + s.zoneHi) * 0.5;
   bool overlaps = (m1[1].low <= s.zoneHi && m1[1].high >= s.zoneLo);
   if(!overlaps) return false;

   if(bull)
      return (m1[1].close > m1[1].open && m1[1].close > mid);
   return (m1[1].close < m1[1].open && m1[1].close < mid);
}

//=========================== ORDER PLACEMENT ========================//
bool DailyLimitsOK()
{
   if(InpMaxDailyLossR <= 0) return true;

   double pl = 0.0;
   int entries = 0;
   if(!TodayStats(pl, entries))
   {
      g_status = "WAITING";
      g_reason = "Deal history unavailable";
      return false;
   }

   // Define 1R as the configured risk amount on current equity. This makes
   // the daily stop independent of the number of trades taken.
   double riskPercent = (InpRiskPercent > 0.0 ? InpRiskPercent : 0.25);
   double oneRMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPercent / 100.0;
   double dailyLimit = oneRMoney * InpMaxDailyLossR;
   if(pl + FloatingPL() <= -dailyLimit)
   {
      g_status = "WAITING";
      g_reason = "Daily loss limit reached (" + DoubleToString(InpMaxDailyLossR, 1) + "R)";
      return false;
   }
   return true;
}

bool PlaceOrder(bool bull, const Setup &s)
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = PointValue();
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(ask <= 0 || bid <= 0 || point <= 0)
   {
      g_reason = "No valid price";
      return false;
   }

   double entry = NormalizePrice(s.entry);
   double sl    = NormalizePrice(s.sl);
   double tp    = NormalizePrice(s.tp);

   // v3.1: price has already reached (or passed) the zone, so a resting
   // limit order can't be placed behind the market. Previously this
   // discarded the whole setup; now it takes the trade at market instead,
   // using the live price as entry and re-deriving SL distance from it so
   // the stop is still measured correctly from where we actually got in.
   bool zoneAlreadyTouched = bull ? (entry >= ask - minDist) : (entry <= bid + minDist);
   if(zoneAlreadyTouched)
   {
      double mEntry = bull ? ask : bid;
      double mSl    = sl;   // the invalidation level itself doesn't move
      if(MathAbs(mEntry - mSl) < minDist)
      {
         g_reason = "Market entry too close to SL";
         return false;
      }
      double risk  = MathAbs(mEntry - mSl);
      double mTp   = bull ? mEntry + risk * MathMax(s.rr, 1.0)
                           : mEntry - risk * MathMax(s.rr, 1.0);
      if(MathAbs(mTp - mEntry) < minDist)
      {
         g_reason = "Market TP inside broker stop level";
         return false;
      }

      double mLots = CalcLots(bull, mEntry, mSl);
      if(mLots <= 0.0) return false;

      double mMargin = 0.0;
      if(OrderCalcMargin(bull ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, mLots, mEntry, mMargin) &&
         mMargin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      {
         g_reason = "Not enough free margin";
         return false;
      }

      trade.SetExpertMagicNumber(InpMagicNumber);
      trade.SetDeviationInPoints(15);

      mSl = NormalizePrice(mSl);
      mTp = NormalizePrice(mTp);
      bool mOk = bull ? trade.Buy(mLots, _Symbol, 0.0, mSl, mTp, "TRS3 BULL MKT")
                      : trade.Sell(mLots, _Symbol, 0.0, mSl, mTp, "TRS3 BEAR MKT");

      if(mOk)
      {
         g_lastSignal = bull ? "BUY (market)" : "SELL (market)";
         g_status = "EXECUTED";
         g_reason = "Zone already touched - took it at market";
         string mMsg = StringFormat("Treasure v3.5 %s %s %.2f lots @ market | SL %s | TP %s",
                     _Symbol, g_lastSignal, mLots,
                     DoubleToString(mSl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                     DoubleToString(mTp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
         Print(mMsg);
         if(InpAlertOnTrade)
         {
            Alert(mMsg);
            SendNotification(mMsg);
         }
         return true;
      }

      g_reason = "Market order failed: " + trade.ResultRetcodeDescription();
      return false;
   }

   if(MathAbs(entry - sl) < minDist || MathAbs(tp - entry) < minDist)
   {
      g_reason = "SL/TP inside broker stop level";
      return false;
   }

   double lots = CalcLots(bull, entry, sl);
   if(lots <= 0.0) return false;

   double margin = 0.0;
   if(OrderCalcMargin(bull ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      g_reason = "Not enough free margin";
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   bool ok;
   if(bull)
      ok = trade.BuyLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "TRS3 BULL");
   else
      ok = trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "TRS3 BEAR");

   if(ok)
   {
      g_lastSignal = bull ? "BUY LIMIT" : "SELL LIMIT";
      g_status = "ARMED";
      g_reason = "Limit order placed at FVG after M1 confirmation";
      string msg = StringFormat("Treasure v3.5 %s %.2f lots @ %s | SL %s | TP %s | RR %.1f",
                  g_lastSignal, lots,
                  DoubleToString(entry, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  DoubleToString(sl,    (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  DoubleToString(tp,    (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  s.rr);
      Print(msg);
      if(InpAlertOnTrade)
      {
         Alert(msg);
         SendNotification(msg);
      }
      return true;
   }

   g_reason = "Order failed: " + trade.ResultRetcodeDescription();
   return false;
}

// 0 = nothing to do, 1 = handled (status / reason already set)
int TryPlace()
{
   bool bullOK = (g_bull.stage == 5) && (!InpUseBias || g_biasBull) && (g_bull.key != g_usedKeyBull);
   bool bearOK = (g_bear.stage == 5) && (!InpUseBias || g_biasBear) && (g_bear.key != g_usedKeyBear);
   if(!bullOK && !bearOK) return 0;

   if(!g_inKZ)
   {
      g_status = "WAITING";
      g_reason = "Setup ready - waiting for kill zone";
      return 1;
   }

   if(!SpreadOK())
   {
      g_status = "WAITING";
      g_reason = "Spread too high";
      return 1;
   }

   if(CountMyPositions() + CountMyPendings() >= InpMaxActive)
   {
      g_status = "SCANNING";
      g_reason = "Max active trades reached";
      return 1;
   }

   bool bull;
   if(bullOK && bearOK) bull = (g_bull.key >= g_bear.key);
   else                 bull = bullOK;

   Setup s = bull ? g_bull : g_bear;

   // Require a completed M1 candle to confirm the retracement direction.
   // Do not consume the setup key until confirmation is present.
   if(!M1EntryConfirm(bull, s))
   {
      g_status = "CONFIRMING";
      g_reason = "Waiting for M1 candle confirmation inside FVG";
      return 1;
   }

   // One attempt per setup, whatever the outcome.
   if(bull) g_usedKeyBull = s.key;
   else     g_usedKeyBear = s.key;

   if(!DailyLimitsOK()) return 1;

   if(!PlaceOrder(bull, s))
      g_status = "REJECTED";
   return 1;
}

//========================== ORDER / POSITION MANAGEMENT =============//
void ManagePendings(bool newBar)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long maxAge = (long)InpOrderExpiryBars * PeriodSeconds(InpExecTF);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;

      long type = OrderGetInteger(ORDER_TYPE);
      bool isBuy  = (type == ORDER_TYPE_BUY_LIMIT);
      bool isSell = (type == ORDER_TYPE_SELL_LIMIT);
      if(!isBuy && !isSell) continue;

      double sl = OrderGetDouble(ORDER_SL);
      bool   kill = false;
      string why = "";

      long age = (long)(TimeCurrent() - (datetime)OrderGetInteger(ORDER_TIME_SETUP));
      if(age > maxAge)
      {
         kill = true; why = "expired";
      }
      else if(isBuy && sl > 0 && bid <= sl)
      {
         kill = true; why = "setup invalidated";
      }
      else if(isSell && sl > 0 && ask >= sl)
      {
         kill = true; why = "setup invalidated";
      }
      else if(newBar && InpUseBias && ((isBuy && g_biasBear) || (isSell && g_biasBull)))
      {
         kill = true; why = "HTF bias flipped";
      }

      if(kill && trade.OrderDelete(tk))
      {
         g_reason = "Pending order cancelled: " + why;
         Print("Treasure v3.4: pending order cancelled - ", why);
      }
   }
}

void ManagePositions()
{
   static datetime lastRun = 0;
   datetime now = TimeCurrent();
   if(now == lastRun) return;       // at most once per second
   lastRun = now;

   if(InpBreakEvenAtR <= 0 && InpPartialAtR <= 0) return;

   double point   = PointValue();
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   id   = PositionGetInteger(POSITION_IDENTIFIER);

      // Remember the ORIGINAL risk (R) even after SL moves to break-even.
      string gR = "TRS3_R_" + IntegerToString(id);
      double R;
      if(GlobalVariableCheck(gR))
         R = GlobalVariableGet(gR);
      else
      {
         if(sl <= 0) continue;
         R = MathAbs(open - sl);
         GlobalVariableSet(gR, R);
      }
      if(R <= 0) continue;

      double px   = buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double prof = buy ? (px - open) : (open - px);

      // Optional partial close.
      if(InpPartialAtR > 0 && prof >= InpPartialAtR * R)
      {
         string gP = "TRS3_P_" + IntegerToString(id);
         if(!GlobalVariableCheck(gP))
         {
            double vol  = PositionGetDouble(POSITION_VOLUME);
            double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double cv   = NormalizeVolume(vol * InpPartialPercent / 100.0, true);
            if(cv > 0 && (vol - cv) >= vmin)
            {
               if(trade.PositionClosePartial(tk, cv))
                  GlobalVariableSet(gP, 1);
            }
            else
               GlobalVariableSet(gP, 1);   // cannot split this size - do not retry
         }
      }

      // Break-even.
      if(InpBreakEvenAtR > 0 && prof >= InpBreakEvenAtR * R)
      {
         double newSL = buy ? open + InpBEBufferPoints * point
                            : open - InpBEBufferPoints * point;
         newSL = NormalizePrice(newSL);

         bool better = buy ? (sl < newSL) : (sl > newSL || sl <= 0);
         bool distOK = buy ? (px - newSL >= minDist) : (newSL - px >= minDist);

         if(better && distOK)
            trade.PositionModify(tk, newSL, tp);
      }
   }
}

//=====================================================================//
//                            AI HUD                                   //
//=====================================================================//
color Dim(color c, double f)
{
   uint v = (uint)c;
   int r = (int)(v & 0xFF);
   int g = (int)((v >> 8) & 0xFF);
   int b = (int)((v >> 16) & 0xFF);
   return (color)(((int)(b * f) << 16) | ((int)(g * f) << 8) | (int)(r * f));
}

color StatusColor(string s)
{
   if(s == "ARMED" || s == "IN TRADE") return C_GREEN;
   if(s == "REJECTED")                 return C_RED;
   if(s == "WAITING")                  return C_AMBER;
   if(s == "STALKING")                 return C'120,200,255';
   if(s == "STARTING")                 return C_DIM;
   return C_CYAN;
}

void HudRect(string n, int x, int y, int w, int h, color bg, color border)
{
   string name = HUD + n;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
   }
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, g_px + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, g_py + y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
}

void HudRectColor(string n, color bg, color border)
{
   string name = HUD + n;
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
}

void HudRectY(string n, int y)
{
   ObjectSetInteger(0, HUD + n, OBJPROP_YDISTANCE, g_py + y);
}

void HudLabel(string n, int x, int y, string text, color clr, int size = 9,
              ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER, string font = "Consolas")
{
   string name = HUD + n;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
   }
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, g_px + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, g_py + y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void HudSet(string n, string text, color clr)
{
   string name = HUD + n;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void HudSection(string id, int y, string text)
{
   HudLabel("S_" + id, 14, y, text, C_DIM, 8);
   HudRect("R_" + id, 14, y + 14, HUD_W - 28, 1, C_RULE, C_RULE);
}

void RefreshDayStats()
{
   double pl = 0.0;
   int en = 0;
   if(TodayStats(pl, en))
   {
      g_dayPL      = pl + FloatingPL();
      g_dayEntries = en;
   }
}

string g_nodeNames[8] = {"TREND BIAS H1+M30", "SESSION FILTER", "LIQUIDITY SWEEP", "DISPLACEMENT",
                         "FVG RETRACEMENT", "M1 CONFIRMATION", "R:R TARGET", "ORDER / RISK"};

void BuildHud()
{
   ObjectsDeleteAll(0, HUD);
   g_px = InpPanelX;
   g_py = InpPanelY;

   // Frame, glow, header
   HudRect("GLOW", -3, -3, HUD_W + 6, HUD_H + 6, C'0,40,62', C'0,70,100');
   HudRect("BG", 0, 0, HUD_W, HUD_H, C'4,10,18', C_CYAN);
   HudRect("HDR", 1, 1, HUD_W - 2, 34, C'6,26,42', C'6,26,42');
   HudRect("HDRLINE", 1, 35, HUD_W - 2, 2, C_CYAN, C_CYAN);

   // Corner brackets
   HudRect("K1", -3, -3, 18, 3, C_CYAN, C_CYAN);
   HudRect("K2", -3, -3, 3, 18, C_CYAN, C_CYAN);
   HudRect("K3", HUD_W - 15, -3, 18, 3, C_CYAN, C_CYAN);
   HudRect("K4", HUD_W, -3, 3, 18, C_CYAN, C_CYAN);
   HudRect("K5", -3, HUD_H, 18, 3, C_CYAN, C_CYAN);
   HudRect("K6", -3, HUD_H - 15, 3, 18, C_CYAN, C_CYAN);
   HudRect("K7", HUD_W - 15, HUD_H, 18, 3, C_CYAN, C_CYAN);
   HudRect("K8", HUD_W, HUD_H - 15, 3, 18, C_CYAN, C_CYAN);

   HudLabel("TITLE", 14, 8, "TREASURE // AI CORE", C_CYAN, 12);
   HudLabel("ONLINE", HUD_W - 14, 12, "SYS ONLINE", C_GREEN, 8, ANCHOR_RIGHT_UPPER);
   HudLabel("SUB", 14, 42, "TREND + SWEEP + FVG  |  v3.4", C_DIM, 8);

   // Status badge
   HudRect("BADGE", 14, 62, HUD_W - 28, 26, C'6,26,42', C_CYAN);
   HudRect("PULSE", 24, 71, 8, 8, C_CYAN, C_CYAN);
   HudLabel("STATUS", HUD_W / 2, 67, "STARTING", C_CYAN, 10, ANCHOR_UPPER);

   // Market state
   HudSection("MKT", 100, "// MARKET STATE");
   HudLabel("BIASL", 14, 122, "H1 + M30 TREND BIAS", C_TEXT, 9);
   HudLabel("BIASV", HUD_W - 14, 120, "NEUTRAL", C_AMBER, 12, ANCHOR_RIGHT_UPPER);

   // Neural nodes
   HudSection("NODE", 152, "// SETUP SEQUENCE");
   HudLabel("HB", 257, 152, "BULL", C_GREEN, 8, ANCHOR_UPPER);
   HudLabel("HR", 317, 152, "BEAR", C_RED, 8, ANCHOR_UPPER);
   for(int i = 0; i < 8; i++)
   {
      int y = 176 + i * 20;
      HudLabel("NN" + IntegerToString(i), 14, y, g_nodeNames[i], C_TEXT, 9);
      HudRect("LB" + IntegerToString(i), 252, y + 2, 10, 10, C_OFF, C_OFF);
      HudRect("LR" + IntegerToString(i), 312, y + 2, 10, 10, C_OFF, C_OFF);
   }

   // Progress energy bar
   HudSection("CONF", 346, "// SETUP PROGRESS");
   HudLabel("SCORE", HUD_W - 14, 344, "0 / 8", C_CYAN, 10, ANCHOR_RIGHT_UPPER);
   for(int i = 0; i < 8; i++)
      HudRect("SEG" + IntegerToString(i), 14 + i * 42, 368, 38, 12, C_OFF, C_OFF);
   HudLabel("MARK", 14 + 7 * 42, 384, "^ ARMED", C_AMBER, 8);

   // Telemetry
   HudSection("TEL", 406, "// TELEMETRY");
   HudLabel("T1L", 14, 428, "SPREAD", C_DIM, 9);
   HudLabel("T1V", 100, 428, "-", C_TEXT, 9);
   HudLabel("T2L", 196, 428, "ACTIVE", C_DIM, 9);
   HudLabel("T2V", 290, 428, "-", C_TEXT, 9);
   HudLabel("T3L", 14, 446, "DAY P/L", C_DIM, 9);
   HudLabel("T3V", 100, 446, "-", C_TEXT, 9);
   HudLabel("T4L", 196, 446, "FILLS", C_DIM, 9);
   HudLabel("T4V", 290, 446, "-", C_TEXT, 9);
   HudLabel("T5L", 14, 464, "LAST ORDER", C_DIM, 9);
   HudLabel("T5V", 100, 464, "-", C_TEXT, 9);
   HudLabel("T6L", 196, 464, "MIN R:R", C_DIM, 9);
   HudLabel("T6V", 290, 464, "-", C_TEXT, 9);

   // AI console
   HudSection("AI", 492, "// AI CONSOLE");
   HudRect("CON", 14, 512, HUD_W - 28, 66, C'2,6,12', C_RULE);
   HudLabel("CL1", 20, 518, "> ", C_GREEN, 9);
   HudLabel("CL2", 20, 534, "> ", C_GREEN, 9);
   HudLabel("STREAM", 20, 556, "STREAM", C'0,110,80', 8);

   // Footer
   HudLabel("FOOTL", 14, 588, "", C_DIM, 8);
   HudLabel("FOOTR", HUD_W - 14, 588, "", C_DIM, 8, ANCHOR_RIGHT_UPPER);

   // Scan line (created last so it draws on top)
   HudRect("SCAN", 1, 40, HUD_W - 2, 1, C'0,110,150', C'0,110,150');

   RefreshDayStats();
}

void UpdateHud()
{
   bool blink = ((g_tick % 4) < 2);

   if(g_tick % 40 == 1) RefreshDayStats();

   // --- status badge + pulse LED
   color sc = StatusColor(g_status);
   HudRectColor("BADGE", Dim(sc, 0.18), sc);
   HudRectColor("PULSE", blink ? sc : Dim(sc, 0.25), blink ? sc : Dim(sc, 0.25));
   HudSet("STATUS", "<< " + g_status + " >>", sc);

   // --- bias
   string bias = "NEUTRAL";
   color  bc   = C_AMBER;
   if(g_biasBull) { bias = "/\\ BULLISH"; bc = C_GREEN; }
   if(g_biasBear) { bias = "\\/ BEARISH"; bc = C_RED; }
   HudSet("BIASV", bias, bc);

   // --- setup sequence LEDs
   bool hasBuy = false, hasSell = false;
   ActiveDirs(hasBuy, hasSell);

   bool bull[8], bear[8];
   bull[0] = g_biasBull;          bear[0] = g_biasBear;
   bull[1] = g_inKZ;              bear[1] = g_inKZ;
   bull[2] = (g_bull.stage >= 1); bear[2] = (g_bear.stage >= 1);
   bull[3] = (g_bull.stage >= 2); bear[3] = (g_bear.stage >= 2);
   bull[4] = (g_bull.stage >= 3); bear[4] = (g_bear.stage >= 3);
   bull[5] = (g_bull.stage >= 4); bear[5] = (g_bear.stage >= 4);
   bull[6] = (g_bull.stage >= 5); bear[6] = (g_bear.stage >= 5);
   bull[7] = hasBuy;              bear[7] = hasSell;

   int cntBull = 0, cntBear = 0;
   for(int i = 0; i < 8; i++)
   {
      string id = IntegerToString(i);
      HudRectColor("LB" + id, bull[i] ? C_GREEN : C_OFF, bull[i] ? C_GREEN : C_OFF);
      HudRectColor("LR" + id, bear[i] ? C_RED   : C_OFF, bear[i] ? C_RED   : C_OFF);
      ObjectSetInteger(0, HUD + "NN" + id, OBJPROP_COLOR,
                       (bull[i] || bear[i]) ? C'225,245,255' : C_TEXT);
      if(bull[i]) cntBull++;
      if(bear[i]) cntBear++;
   }
   int score = MathMax(cntBull, cntBear);

   // --- progress bar
   color segOn = (score >= 7) ? C_GREEN : C_CYAN;
   for(int i = 0; i < 8; i++)
   {
      color c = (i < score) ? segOn : C_OFF;
      HudRectColor("SEG" + IntegerToString(i), c, c);
   }
   HudSet("SCORE", IntegerToString(score) + " / 8", segOn);

   // --- telemetry
   double point  = PointValue();
   double spread = (point > 0) ? (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point : 0;
   HudSet("T1V", DoubleToString(spread, 0) + " pts",
          spread <= InpMaxSpreadPoints ? C_TEXT : C_RED);
   HudSet("T2V", IntegerToString(CountMyPositions() + CountMyPendings()) + " / " +
          IntegerToString(InpMaxActive), C_TEXT);
   HudSet("T3V", (g_dayPL >= 0 ? "+" : "") + DoubleToString(g_dayPL, 2),
          g_dayPL >= 0 ? C_GREEN : C_RED);
   HudSet("T4V", IntegerToString(g_dayEntries) + " trades today", C_TEXT);
   color lc = (StringFind(g_lastSignal, "BUY") >= 0) ? C_GREEN :
              (StringFind(g_lastSignal, "SELL") >= 0 ? C_RED : C_DIM);
   HudSet("T5V", g_lastSignal, lc);
   HudSet("T6V", "1 : " + DoubleToString(InpMinRR, 1), C_TEXT);

   // --- AI console (reason wrapped over two lines, blinking cursor)
   string cur = blink ? "_" : " ";
   string r1  = StringSubstr(g_reason, 0, 40);
   string r2  = (StringLen(g_reason) > 40) ? StringSubstr(g_reason, 40, 40) : "";
   string line2;
   if(r2 != "")
      line2 = "  " + r2 + cur;
   else
      line2 = StringFormat("> bull %d/5 | bear %d/5 | KZ %s%s",
                           g_bull.stage, g_bear.stage, g_inKZ ? "ON" : "OFF", cur);
   HudSet("CL1", "> " + r1, C_GREEN);
   HudSet("CL2", line2, Dim(C_GREEN, 0.75));

   // --- data stream
   string s = "STREAM ";
   for(int i = 0; i < 6; i++)
      s += StringFormat("%04X ", (MathRand() << 1) | (MathRand() & 1));
   HudSet("STREAM", s, C'0,110,80');

   // --- footer
   HudSet("FOOTL", _Symbol + " / " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), C_DIM);
   HudSet("FOOTR", TimeToString(TimeCurrent(), TIME_SECONDS), C_DIM);

   // --- scan line sweeps down the panel
   HudRectY("SCAN", 40 + (int)((g_tick * 6) % (HUD_H - 44)));
}

//========================= CHART OVERLAYS ===========================//
void DrawText(string name, datetime t, double price, string text, color clr,
              ENUM_ANCHOR_POINT anchor)
{
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DrawOneSetup(const Setup &s, bool bull, string tag)
{
   if(s.stage < 1) return;

   color cz = bull ? C'0,230,120' : C'255,70,90';
   ENUM_ANCHOR_POINT below = bull ? ANCHOR_UPPER : ANCHOR_LOWER;
   ENUM_ANCHOR_POINT above = bull ? ANCHOR_LOWER : ANCHOR_UPPER;

   // Sweep marker
   DrawText("TRS_Z_SW" + tag, s.sweepT, s.sweepLevel, "SWEEP", C_AMBER, below);

   if(s.stage < 2) return;

   // MSS level + label
   string ln = "TRS_Z_MSS" + tag;
   if(ObjectCreate(0, ln, OBJ_TREND, 0, s.mssFromT, s.mssLevel, s.mssT, s.mssLevel))
   {
      ObjectSetInteger(0, ln, OBJPROP_COLOR, C_CYAN);
      ObjectSetInteger(0, ln, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, ln, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, ln, OBJPROP_HIDDEN, true);
   }
   DrawText("TRS_Z_MSST" + tag, s.mssT, s.mssLevel, "MSS", C_CYAN, above);

   if(s.zoneT == 0 || s.zoneHi <= s.zoneLo) return;

   // Entry zone (FVG dotted, OB solid)
   datetime t2 = TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 12);
   string zn = "TRS_Z_ZONE" + tag;
   if(ObjectCreate(0, zn, OBJ_RECTANGLE, 0, s.zoneT, s.zoneHi, t2, s.zoneLo))
   {
      ObjectSetInteger(0, zn, OBJPROP_COLOR, cz);
      ObjectSetInteger(0, zn, OBJPROP_STYLE, s.isFVG ? STYLE_DOT : STYLE_SOLID);
      ObjectSetInteger(0, zn, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zn, OBJPROP_FILL, false);
      ObjectSetInteger(0, zn, OBJPROP_BACK, true);
      ObjectSetInteger(0, zn, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, zn, OBJPROP_HIDDEN, true);
   }
   DrawText("TRS_Z_ZT" + tag, s.zoneT, bull ? s.zoneLo : s.zoneHi,
            s.isFVG ? "FVG" : "OB", cz, bull ? ANCHOR_UPPER : ANCHOR_LOWER);
}

void DrawSetupOverlays()
{
   if(!HudActive() || !InpDrawZones) return;

   ObjectsDeleteAll(0, "TRS_Z_");
   DrawOneSetup(g_bull, true,  "B");
   DrawOneSetup(g_bear, false, "S");
   ChartRedraw(0);
}

void SetHLine(string name, double price, color clr, string text)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

// Entry / SL / TP lines for the open position, or the live pending order.
void DrawTradeLines()
{
   bool found = false;
   double entry = 0, sl = 0, tp = 0;
   string tag = "ENTRY";

   for(int i = PositionsTotal() - 1; i >= 0 && !found; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
      sl    = PositionGetDouble(POSITION_SL);
      tp    = PositionGetDouble(POSITION_TP);
      found = true;
   }

   for(int i = OrdersTotal() - 1; i >= 0 && !found; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      long t = OrderGetInteger(ORDER_TYPE);
      if(t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_SELL_LIMIT) continue;
      entry = OrderGetDouble(ORDER_PRICE_OPEN);
      sl    = OrderGetDouble(ORDER_SL);
      tp    = OrderGetDouble(ORDER_TP);
      tag   = "LIMIT";
      found = true;
   }

   if(!found)
   {
      ObjectsDeleteAll(0, "TRS_L_");
      return;
   }

   SetHLine("TRS_L_ENTRY", entry, C_CYAN, tag);
   if(sl > 0) SetHLine("TRS_L_SL", sl, C_RED,   "SL");
   if(tp > 0) SetHLine("TRS_L_TP", tp, C_GREEN, "TP");
}

//========================== CHART THEME =============================//
void ApplyTheme()
{
   if(!InpApplyChartTheme || !HudActive()) return;

   long vals[8];
   vals[0] = C'3,8,16';       // background
   vals[1] = C'95,150,170';   // foreground
   vals[2] = C'12,28,40';     // grid
   vals[3] = C'0,230,200';    // bar up
   vals[4] = C'255,60,100';   // bar down
   vals[5] = C'0,230,200';    // line
   vals[6] = C'0,230,200';    // candle bull
   vals[7] = C'255,60,100';   // candle bear

   for(int i = 0; i < 8; i++)
   {
      ENUM_CHART_PROPERTY_INTEGER p = (ENUM_CHART_PROPERTY_INTEGER)g_themeIds[i];
      g_themeSaved[i] = ChartGetInteger(0, p);
      ChartSetInteger(0, p, vals[i]);
   }
   g_themeOn = true;
}

void RestoreTheme()
{
   if(!g_themeOn) return;
   for(int i = 0; i < 8; i++)
      ChartSetInteger(0, (ENUM_CHART_PROPERTY_INTEGER)g_themeIds[i], g_themeSaved[i]);
   g_themeOn = false;
}

//=========================== EXEC-BAR REFRESH =======================//
// Rebuild liquidity and M5 setup once per new setup-TF bar. H1 structure
// is recalculated only when a new H1 candle begins (the prior H1 candle closed).
// If data is unavailable, timestamps are not advanced and the next tick retries.
bool RefreshExec()
{
   datetime t = iTime(_Symbol, InpExecTF, 0);
   if(t == 0) return g_execReady;

   datetime h1Bar = iTime(_Symbol, PERIOD_H1, 0);
   if(h1Bar == 0) return false;
   if(h1Bar != g_lastH1Bar)
   {
      int h1Bias = 0;
      if(!HtfBias(PERIOD_H1, h1Bias)) return false;
      g_cachedH1Bias = h1Bias;
      g_lastH1Bar = h1Bar;
      g_biasBull = (g_cachedH1Bias == 1);
      g_biasBear = (g_cachedH1Bias == -1);
   }

   if(g_execReady && t == g_lastExec) return true;
   g_execReady = false;

   MqlRates r[];
   if(!GetRatesAdaptive(InpExecTF, InpScanBars, 60, r)) return false;

   double hi = 0, lo = 0;
   g_eqValid = DealingRange(hi, lo);
   g_eq = g_eqValid ? (hi + lo) / 2.0 : 0.0;

   if(!BuildLiquidity(r)) return false;

   double atr = ATRValue(r, 14);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(atr <= 0 || ask <= 0 || bid <= 0) return false;

   FindSetup(true,  r, atr, g_eqValid, g_eq, ask, bid, g_bull, g_noteBull);
   FindSetup(false, r, atr, g_eqValid, g_eq, ask, bid, g_bear, g_noteBear);

   g_lastExec  = t;
   g_execReady = true;

   ManagePendings(true);
   DrawSetupOverlays();
   return true;
}

//=========================== TICK ENGINE ============================//
void FastTickEngine()
{
   ManagePositions();
   ManagePendings(false);

   bool ready = RefreshExec();
   g_inKZ = InKillZone();

   if(CountMyPositions() > 0)
   {
      g_status = "IN TRADE";
      g_reason = "Managing open position";
      return;
   }

   if(CountMyPendings() > 0)
   {
      g_status = "ARMED";
      g_reason = "Limit order resting at the entry zone";
      return;
   }

   if(!ready)
   {
      ulong elapsedMs = GetTickCount() - g_initMs;
      g_status = "WAITING";
      if(elapsedMs < (ulong)(InpMaxWarmupSeconds * 1000))
      {
         int secsLeft = InpMaxWarmupSeconds - (int)(elapsedMs / 1000);
         g_reason = StringFormat("Downloading chart history (falls back to reduced data in %ds)", secsLeft);
      }
      else
         g_reason = "Still no usable history even with reduced-data fallback - check symbol/connection";
      return;
   }

   if(g_reducedHistory && !g_reducedNotified)
   {
      string wmsg = "Treasure v3.4: running on reduced history after " +
                    IntegerToString(InpMaxWarmupSeconds) + "s warm-up - signals may be less reliable until full history backfills.";
      Print(wmsg);
      if(InpAlertOnTrade) Alert(wmsg);
      g_reducedNotified = true;
   }

   if(TryPlace() == 1) return;

   // Nothing placed: describe the most advanced setup.
   bool useBull = (g_bull.stage >= g_bear.stage);
   int  st      = useBull ? g_bull.stage : g_bear.stage;
   string note  = useBull ? g_noteBull : g_noteBear;

   if(st >= 2)
   {
      g_status = "STALKING";
      g_reason = note;
      if(st == 5)
      {
         bool biasOK = useBull ? g_biasBull : g_biasBear;
         if(InpUseBias && !biasOK)
            g_reason = note + " - HTF bias disagrees";
      }
   }
   else
   {
      g_status = "SCANNING";
      g_reason = (st == 1) ? note : "No qualifying liquidity sweep";
   }
}

//========================== MT5 EVENTS ==============================//
int OnInit()
{
   if(InpFractalLen < 1 || InpFractalLen > 5 ||
      InpHtfFractalLen < 1 || InpHtfFractalLen > 5 ||
      InpScanBars < 120 || InpScanBars > 1000 ||
      InpMaxWarmupSeconds < 30 || InpMaxWarmupSeconds > 1800 ||
      InpSetupMaxAgeBars < 5 || InpMaxSweepToMSSBars < 2 || InpMSSLookback < 5 ||
      InpEntryPct < 0 || InpEntryPct > 100 ||
      InpMinRR <= 0 || InpMaxActive < 1 ||
      InpRiskPercent < 0 || InpMaxDailyLossR < 0 ||
      InpPartialPercent <= 0 || InpPartialPercent >= 100 ||
      PeriodSeconds(InpExecTF) > 3600 || PeriodSeconds(InpExecTF) < 60)
   {
      Print("Treasure v3.5: invalid input parameters (setup TF must be M1..H1)");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   ZeroMemory(g_bull);
   ZeroMemory(g_bear);
   g_noteBull = "";
   g_noteBear = "";
   g_biasBull = false;
   g_biasBear = false;
   g_inKZ     = false;
   g_usedKeyBull = 0;
   g_usedKeyBear = 0;
   g_execReady = false;
   g_lastExec  = 0;
   g_lastH1Bar = 0;
   g_cachedH1Bias = 0;
   g_tick = 0;
   g_initMs = GetTickCount();
   g_reducedHistory = false;
   g_reducedNotified = false;

   ArrayResize(g_sweepLows, 0);
   ArrayResize(g_sweepHighs, 0);
   ArrayResize(g_tgtHighs, 0);
   ArrayResize(g_tgtLows, 0);

   g_status = "RUNNING";
   g_reason = "Scanning H1 bias -> M5 sweep/displacement/FVG -> M1 retracement";

   MathSrand((int)GetTickCount());

   if(HudActive())
   {
      ApplyTheme();

      if(InpDrawTradeLines)
      {
         g_descrSaved   = ChartGetInteger(0, CHART_SHOW_OBJECT_DESCR);
         g_descrChanged = true;
         ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);
      }

      if(InpShowDashboard)
         BuildHud();

      EventSetMillisecondTimer(500);
      ChartRedraw(0);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, HUD);       // HUD, overlays (TRS_Z_) and lines (TRS_L_)
   RestoreTheme();
   if(g_descrChanged)
   {
      ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, g_descrSaved);
      g_descrChanged = false;
   }
   ChartRedraw(0);
}

void OnTimer()
{
   if(!HudActive()) return;

   g_tick++;
   if(InpShowDashboard)
      UpdateHud();
   if(InpDrawTradeLines && (g_tick % 4) == 0)
      DrawTradeLines();
   ChartRedraw(0);
}

void OnTick()
{
   FastTickEngine();
}
//+------------------------------------------------------------------+
