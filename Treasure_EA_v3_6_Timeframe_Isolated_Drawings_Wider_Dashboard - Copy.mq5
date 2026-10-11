//+------------------------------------------------------------------+
//| TREASURE EA v3.6 - MARKET INTELLIGENCE + SMC/ICT DECISION TRACE             |
//|                                                                  |
//| Strategy pipeline:                                               |
//| 1. H1 directional market structure                               |
//| 2. M30 and M15 structural alignment                              |
//| 3. ICT liquidity: swing highs/lows, PDH/PDL, Asian range          |
//| 4. Liquidity sweep and reclaim                                   |
//| 5. Market Structure Shift (MSS) with displacement                |
//| 6. Fresh Fair Value Gap (FVG), no legacy OB fallback             |
//| 7. Premium/discount location and ICT kill-zone filter            |
//| 8. Completed M1 candle confirmation                              |
//| 9. Market intelligence: regime, volatility, momentum, efficiency |
//| 10. Opposing-liquidity target, risk checks and duplicate control |
//|                                                                  |
//| No EMA, RSI, MACD, or alternative strategy engine is used.       |
//+------------------------------------------------------------------+
#property version   "3.60"
#property description "Treasure EA v3.6 - SMC/ICT-only AI-style market intelligence: structure, liquidity, MSS, FVG, regime, volatility, momentum and signal scoring"

#include <Trade/Trade.mqh>
CTrade trade;


//============================== INPUTS ==============================//
input group "Trade"
input double InpRiskPercent           = 0.25;   // Risk per trade, % of equity (0 = fixed lots)
input double InpLots                  = 0.01;   // Fixed lots (used only when Risk % = 0)
input long   InpMagicNumber           = 31001;
input int    InpMaxActive             = 0;      // Maximum active positions/orders (0 = unlimited)
input int    InpSLBufferPoints        = 50;     // SL buffer beyond the sweep extreme (gold-scale)
input int    InpMaxSLPoints           = 4000;   // Reject setups with wider SL (0 = off)
input int    InpTPBufferPoints        = 10;     // TP placed this far before the liquidity

input group "Targets and orders"
input double InpMinRR                 = 2.0;    // Minimum reward:risk target
input double InpFallbackRR            = 0.0;    // ICT-only: require opposing-liquidity target; 0 = skip if none
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
input bool   InpUseKillZones          = true;   // ICT session filter: London / NY kill zones
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
input double InpEntryPct              = 50.0;   // Entry depth in zone: 0 = proximal edge, 50 = CE, 100 = distal
input bool   InpRequirePD             = true;   // ICT premium/discount location filter is required
input bool   InpUseBias               = true;   // Required higher-timeframe ICT/SMC directional bias
input bool   InpRequireH1Agree        = true;   // H1 structural bias is part of the strategy
input bool   InpUsePDHL               = true;   // Previous-day high/low as potential sweep levels
input bool   InpUseAsia               = true;   // Include completed Asian-session high/low liquidity

input group "Signal intelligence v3.5"
input bool   InpRequireM30Agree       = true;   // Require M30 structure to agree with H1 bias
input bool   InpRequireM15Agree       = true;   // Require M15 structure to confirm direction
input int    InpMinSignalScore        = 75;     // Minimum setup-quality score (not win probability)

input group "Market intelligence v3.6"
input bool   InpUseMarketIntelligence = true;   // Add market regime/momentum/volatility intelligence to SMC/ICT
input int    InpMinIntelScore         = 55;     // Minimum directional intelligence score (not win probability)
input int    InpIntelLookback         = 12;     // Closed bars used for momentum/efficiency
input double InpMinATRRegimeRatio     = 0.50;   // Reject extremely quiet conditions if below this ATR ratio
input double InpMaxATRRegimeRatio     = 2.80;   // Reject abnormal volatility if above this ATR ratio

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
#define HUD_W     680
#define HUD_H     500

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
   int      score;           // deterministic setup-quality score, 0..100
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
int      g_cachedM30Bias = 0;
int      g_cachedM15Bias = 0;
datetime g_lastM30Bar = 0;
datetime g_lastM15Bar = 0;

// AI-style market intelligence (deterministic, transparent rules; not a trained ML model)
string   g_marketRegime = "CALIBRATING";
string   g_marketIntelNote = "Collecting closed-candle data";
double   g_atrRegimeRatio = 1.0;
double   g_marketEfficiency = 0.0;
double   g_marketMomentumATR = 0.0;
int      g_intelScoreBull = 0;
int      g_intelScoreBear = 0;


// v3.3 warm-up: timestamp the EA was attached, so history requirements
// can relax if the broker hasn't delivered full HTF history in time.
ulong    g_initMs        = 0;
bool     g_reducedHistory = false;
bool     g_reducedNotified = false;

// HUD state
int      g_px = 15;
int      g_py = 30;
bool     g_hudMinimized = false;
bool     g_analysisRunning = false;
bool     g_signalWasDetected = false;
ulong    g_startAtMs = 0;
ulong    g_rejectUntilMs = 0;
string   g_signalState = "STOPPED";
datetime g_lastDisplayedSignal = 0;
double   g_totalCollectedPL = 0.0;
int      g_accountPositions = 0;
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
      pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

// Account-wide realized net P/L, including manual trades and all symbols.
bool AccountHistoryPL(datetime from, double &pl, int &entries)
{
   pl = 0.0; entries = 0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return false;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT) entries++;
      pl += HistoryDealGetDouble(tk, DEAL_PROFIT)
          + HistoryDealGetDouble(tk, DEAL_SWAP)
          + HistoryDealGetDouble(tk, DEAL_COMMISSION)
          + HistoryDealGetDouble(tk, DEAL_FEE);
   }
   return true;
}

// Realised P/L (incl. commission, swap, fees) and filled-entry count for
// today (broker server day), for deals carrying this EA's magic number.
bool TodayStats(double &pl, int &entries)
{
   MqlDateTime d; TimeToStruct(TimeCurrent(), d);
   d.hour = 0; d.min = 0; d.sec = 0;
   return AccountHistoryPL(StructToTime(d), pl, entries);
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


// Transparent, deterministic market-intelligence layer. It supplements (never
// replaces) the SMC/ICT setup rules. Scores are confluence scores, not odds.
bool UpdateMarketIntelligence(const MqlRates &r[], double atr)
{
   int n = ArraySize(r);
   int lookback = MathMax(4, InpIntelLookback);
   if(n < lookback + 25 || atr <= 0.0) return false;
   double trSum = 0.0;
   for(int i = 1; i <= 20; i++)
   {
      double tr = r[i].high - r[i].low;
      tr = MathMax(tr, MathAbs(r[i].high - r[i+1].close));
      tr = MathMax(tr, MathAbs(r[i].low - r[i+1].close));
      trSum += tr;
   }
   double avgTR = trSum / 20.0;
   g_atrRegimeRatio = (avgTR > 0.0 ? atr / avgTR : 1.0);
   double netMove = r[1].close - r[lookback+1].close;
   double path = 0.0;
   int bullBars = 0, bearBars = 0;
   for(int i = 1; i <= lookback; i++)
   {
      path += MathAbs(r[i].close - r[i+1].close);
      if(r[i].close > r[i].open) bullBars++;
      else if(r[i].close < r[i].open) bearBars++;
   }
   g_marketMomentumATR = netMove / atr;
   g_marketEfficiency = (path > 0.0 ? MathAbs(netMove) / path : 0.0);
   if(g_atrRegimeRatio > 1.80) g_marketRegime = "VOLATILITY EXPANSION";
   else if(g_atrRegimeRatio < 0.65) g_marketRegime = "LOW VOLATILITY";
   else if(g_marketEfficiency >= 0.45) g_marketRegime = "DIRECTIONAL TREND";
   else g_marketRegime = "RANGING / MIXED";

   int bull = 35, bear = 35;
   if(g_cachedH1Bias == 1) bull += 15; else if(g_cachedH1Bias == -1) bear += 15;
   if(g_cachedM30Bias == 1) bull += 10; else if(g_cachedM30Bias == -1) bear += 10;
   if(g_cachedM15Bias == 1) bull += 10; else if(g_cachedM15Bias == -1) bear += 10;
   if(g_marketMomentumATR >= 0.35) bull += 15; else if(g_marketMomentumATR <= -0.35) bear += 15;
   if(bullBars > bearBars) bull += 8; else if(bearBars > bullBars) bear += 8;
   if(g_marketEfficiency >= 0.45) { if(netMove > 0) bull += 10; else if(netMove < 0) bear += 10; }
   if(g_atrRegimeRatio >= 0.70 && g_atrRegimeRatio <= 1.80) { bull += 7; bear += 7; }
   if(g_atrRegimeRatio > 2.80) { bull -= 15; bear -= 15; }
   if(g_marketEfficiency < 0.18) { bull -= 5; bear -= 5; }
   g_intelScoreBull = (int)MathMax(0, MathMin(100, bull));
   g_intelScoreBear = (int)MathMax(0, MathMin(100, bear));
   g_marketIntelNote = StringFormat("ATR x%.2f | momentum %.2f ATR | efficiency %.2f", g_atrRegimeRatio, g_marketMomentumATR, g_marketEfficiency);
   return true;
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

   double dispRatio = (atr > 0.0 ? MathAbs(m[mi].close - m[mi].open) / atr : 0.0);

   // ---- stage 3: FVG inside the displacement leg
   double   zLo = 0, zHi = 0;
   double   fvgSizeRatio = 0.0;
   datetime zT = 0;
   bool     haveZone = false, isFVG = false;
   int      zRef = mi;

   // ICT/SMC-only entry array: a genuine three-candle FVG created
   // within the displacement leg. No order-block or legacy-zone fallback.
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

   if(!haveZone)
   {
      cn = side + ": displacement confirmed - no valid FVG in leg";
      return true;
   }

   c.zoneLo = zLo;
   c.zoneHi = zHi;
   fvgSizeRatio = (atr > 0.0 ? (zHi - zLo) / atr : 0.0);
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

   // Deterministic quality score. This is a rule-confluence score, NOT
   // a statistical probability of winning.
   int quality = 15; // valid liquidity sweep and reclaim already confirmed
   bool h1Aligned = (sgn > 0.0 ? g_biasBull : g_biasBear);
   bool m30Aligned = (sgn > 0.0 ? (g_cachedM30Bias == 1) : (g_cachedM30Bias == -1));
   bool m15Aligned = (sgn > 0.0 ? (g_cachedM15Bias == 1) : (g_cachedM15Bias == -1));
   if(h1Aligned) quality += 20;
   if(m30Aligned) quality += 15;
   if(m15Aligned) quality += 10;
   if(dispRatio >= 1.20) quality += 15;
   else if(dispRatio >= 0.90) quality += 10;
   else quality += 5;
   if(fvgSizeRatio >= 0.30) quality += 15;
   else quality += 10;
   quality += 5; // fresh, unmitigated zone passed the validation above
   if(c.rr >= 2.5) quality += 5;
   else if(c.rr >= InpMinRR) quality += 3;
   c.score = MathMin(100, quality);

   c.stage = 5;
   c.valid = true;
   cn = side + ": setup complete | score " + IntegerToString(c.score) +
        "/100 | RR " + DoubleToString(c.rr, 1);
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
         string mMsg = StringFormat("Treasure v3.6 %s %s %.2f lots @ market | SL %s | TP %s",
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
      g_reason = "ICT FVG limit order placed after M1 confirmation";
      string msg = StringFormat("Treasure v3.6 %s %.2f lots @ %s | SL %s | TP %s | RR %.1f",
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

   if(InpMaxActive > 0 && CountMyPositions() + CountMyPendings() >= InpMaxActive)
   {
      g_status = "SCANNING";
      g_reason = "Configured maximum active trades reached";
      return 1;
   }

   bool bull;
   if(bullOK && bearOK) bull = (g_bull.key >= g_bear.key);
   else                 bull = bullOK;

   Setup s = bull ? g_bull : g_bear;

   bool m30Aligned = bull ? (g_cachedM30Bias == 1) : (g_cachedM30Bias == -1);
   if(InpRequireM30Agree && !m30Aligned)
   {
      g_status = "WAITING";
      g_reason = "H1/M30 structure not aligned - no signal";
      return 1;
   }

   bool m15Aligned = bull ? (g_cachedM15Bias == 1) : (g_cachedM15Bias == -1);
   if(InpRequireM15Agree && !m15Aligned)
   {
      g_status = "WAITING";
      g_reason = "M15 structure not confirming direction";
      return 1;
   }

   if(s.score < InpMinSignalScore)
   {
      g_status = "FILTERED";
      g_reason = "Setup score " + IntegerToString(s.score) +
                 "/100 below minimum " + IntegerToString(InpMinSignalScore);
      return 1;
   }

   if(InpUseMarketIntelligence)
   {
      int intel = bull ? g_intelScoreBull : g_intelScoreBear;
      if(g_atrRegimeRatio < InpMinATRRegimeRatio || g_atrRegimeRatio > InpMaxATRRegimeRatio)
      {
         g_status = "FILTERED";
         g_reason = StringFormat("Market intelligence: volatility regime rejected (ATR x%.2f)", g_atrRegimeRatio);
         return 1;
      }
      if(intel < InpMinIntelScore)
      {
         g_status = "FILTERED";
         g_reason = StringFormat("Market intelligence score %d/100 below minimum %d", intel, InpMinIntelScore);
         return 1;
      }
   }

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
   if(s == "SIGNAL DETECTED") return C_GREEN;
   if(s == "INITIALISING") return C_AMBER;
   if(s == "STOPPED") return C_DIM;
   if(s == "REJECTED" || s == "SIGNAL REJECTED") return C_RED;
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
   double pl = 0.0; int en = 0;
   // Collected P/L is today's closed-deal net result only. TodayStats starts
   // at broker-server midnight, so the displayed value resets automatically
   // when a new broker-server day begins. Floating P/L remains separate.
   if(TodayStats(pl, en))
   {
      g_dayPL = pl + FloatingPL();
      g_dayEntries = en;
      g_totalCollectedPL = pl;
   }
}

void DeleteHudPanelOnly()
{
   // Remove dashboard objects only; keep chart overlays and trade lines.
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, HUD) != 0) continue;
      if(StringFind(name, "TRS_Z_") == 0 || StringFind(name, "TRS_L_") == 0) continue;
      ObjectDelete(0, name);
   }
}

void HudButton(string n, int x, int y, int w, int h, string caption)
{
   string name = HUD + n;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, g_px + x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, g_py + y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_COLOR, C_CYAN);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'6,26,42');
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, C_CYAN);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, caption);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 20);
}

void BuildMinimizedHud()
{
   DeleteHudPanelOnly();
   g_px = InpPanelX;
   g_py = InpPanelY;
   HudRect("MINBG", 0, 0, 250, 34, C'4,10,18', C_CYAN);
   HudRect("MINHDR", 1, 1, 248, 32, C'6,26,42', C'6,26,42');
   HudLabel("MINTITLE", 10, 9, "TREASURE EA v3.6  |  MINIMIZED", C_CYAN, 9);
   HudButton("MINBTN", 218, 6, 25, 22, "+");
   ChartRedraw(0);
}

void BuildHud()
{
   DeleteHudPanelOnly();
   g_hudMinimized = false;
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

   HudLabel("TITLE", 14, 8, "TREASURE // MARKET INTELLIGENCE", C_CYAN, 12);
   HudLabel("ONLINE", HUD_W - 43, 12, "SYS ONLINE", C_GREEN, 8, ANCHOR_RIGHT_UPPER);
   HudButton("MINBTN", HUD_W - 31, 6, 24, 22, "-");
   HudLabel("SUB", 14, 42, "SMC/ICT MARKET INTELLIGENCE V3.6  |  Dev GitHub @ letlotlomokoena78", C_DIM, 8);

   // Status badge
   HudRect("BADGE", 14, 62, HUD_W - 28, 26, C'6,26,42', C_CYAN);
   HudRect("PULSE", 24, 71, 8, 8, C_CYAN, C_CYAN);
   HudLabel("STATUS", HUD_W / 2, 67, "STOPPED", C_CYAN, 10, ANCHOR_UPPER);
   HudButton("RUNBTN", 14, 92, HUD_W - 28, 25, "START ANALYSIS");

   // Setup completion percentage replaces the old node-by-node setup sequence
   HudSection("CONF", 124, "// SETUP COMPLETION");
   HudLabel("SCORE", HUD_W - 14, 122, "0%", C_CYAN, 11, ANCHOR_RIGHT_UPPER);
   for(int i = 0; i < 10; i++)
      HudRect("SEG" + IntegerToString(i), 14 + i * 33, 150, 29, 12, C_OFF, C_OFF);
   HudLabel("MARK", 14, 169, "BUY 0%  |  SELL 0%", C_DIM, 8);

   // Account and trading telemetry — aligned two-column layout
   HudSection("TEL", 194, "// ACCOUNT & TRADING");
   HudLabel("T1L", 14, 216, "SPREAD", C_DIM, 8);
   HudLabel("T1V", 82, 216, "-", C_TEXT, 8);
   HudLabel("T4L", 280, 216, "TRADES TODAY", C_DIM, 8);
   HudLabel("T4V", HUD_W - 14, 216, "0", C_TEXT, 9, ANCHOR_RIGHT_UPPER);

   HudLabel("T3L", 14, 236, "CURRENT P/L", C_DIM, 8);
   HudLabel("T3V", 112, 236, "-", C_TEXT, 9);
   HudLabel("T6L", 280, 236, "EQUITY", C_DIM, 8);
   HudLabel("T6V", HUD_W - 14, 236, "-", C_TEXT, 9, ANCHOR_RIGHT_UPPER);

   HudLabel("T5L", 14, 256, "BALANCE", C_DIM, 8);
   HudLabel("T5V", 112, 256, "-", C_TEXT, 9);
   HudLabel("T2L", 280, 256, "ACTIVE POSITIONS", C_DIM, 8);
   HudLabel("T2V", HUD_W - 14, 256, "0", C_TEXT, 8, ANCHOR_RIGHT_UPPER);

      HudLabel("T9L", 14, 276, "COLLECTED P/L", C_DIM, 8);
   HudLabel("T9V", 112, 276, "-", C_TEXT, 9);
   HudLabel("T10L", 280, 276, "ACCOUNT POSITIONS", C_DIM, 8);
   HudLabel("T10V", HUD_W - 14, 276, "0", C_TEXT, 9, ANCHOR_RIGHT_UPPER);

   // Dedicated Market Intelligence section
   HudSection("INTEL", 302, "// MARKET INTELLIGENCE");
   HudLabel("REGIMEL", 14, 324, "REGIME", C_DIM, 8);
   HudLabel("REGIMEV", 92, 324, "CALIBRATING", C_CYAN, 9);
   HudLabel("MOML", 14, 343, "MOMENTUM", C_DIM, 8);
   HudLabel("MOMV", 92, 343, "-", C_TEXT, 9);
   HudLabel("VOLL", 196, 343, "ATR REGIME", C_DIM, 8);
   HudLabel("VOLV", 310, 343, "-", C_TEXT, 9);
   HudLabel("INTELL", 14, 362, "DIRECTIONAL INTEL", C_DIM, 8);
   HudLabel("INTELV", HUD_W - 14, 362, "B 0 / S 0", C_CYAN, 9, ANCHOR_RIGHT_UPPER);
   HudLabel("BIASL", 14, 381, "SMC/ICT BIAS", C_DIM, 8);
   HudLabel("BIASV", HUD_W - 14, 381, "NEUTRAL", C_AMBER, 9, ANCHOR_RIGHT_UPPER);

   // AI console
   HudSection("AI", 406, "// DECISION TRACE");
   HudRect("CON", 14, 426, HUD_W - 28, 56, C'2,6,12', C_RULE);
   HudLabel("CL1", 20, 432, "> ", C_GREEN, 9);
   HudLabel("CL2", 20, 448, "> ", C_GREEN, 9);
   HudLabel("STREAM", 20, 466, "STREAM", C'0,110,80', 8);

   // Footer
   HudLabel("FOOTL", 14, 488, "", C_DIM, 8);
   HudLabel("FOOTR", HUD_W - 14, 488, "", C_DIM, 8, ANCHOR_RIGHT_UPPER);

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

   // --- directional bias, displayed within Market Intelligence
   string bias = "NEUTRAL";
   color  bc   = C_AMBER;
   if(g_biasBull) { bias = "BULLISH"; bc = C_GREEN; }
   if(g_biasBear) { bias = "BEARISH"; bc = C_RED; }
   HudSet("BIASV", bias, bc);

   // --- setup sequence completion percentage (stage 0..5 -> 0..100%)
   int buyPct  = (int)MathMax(0, MathMin(100, g_bull.stage * 20));
   int sellPct = (int)MathMax(0, MathMin(100, g_bear.stage * 20));
   int setupPct = MathMax(buyPct, sellPct);
   color segOn = (setupPct >= 80) ? C_GREEN : C_CYAN;
   for(int i = 0; i < 10; i++)
   {
      color c = (i < (setupPct / 10)) ? segOn : C_OFF;
      HudRectColor("SEG" + IntegerToString(i), c, c);
   }
   HudSet("SCORE", IntegerToString(setupPct) + "%", segOn);
   HudSet("MARK", "BUY " + IntegerToString(buyPct) + "%  |  SELL " + IntegerToString(sellPct) + "%",
          buyPct > sellPct ? C_GREEN : (sellPct > buyPct ? C_RED : C_DIM));

   // --- telemetry
   double point  = PointValue();
   double spread = (point > 0) ? (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point : 0;
   HudSet("T1V", DoubleToString(spread, 0) + " pts",
          spread <= InpMaxSpreadPoints ? C_TEXT : C_RED);
   string activeLimit = (InpMaxActive == 0) ? "ALL" : "CAP " + IntegerToString(InpMaxActive);
   g_accountPositions = PositionsTotal();
   HudSet("T2V", IntegerToString(g_accountPositions) + " active", C_TEXT);
   double floatingPL = FloatingPL();
   HudSet("T3V", (floatingPL >= 0 ? "+" : "") + DoubleToString(floatingPL, 2),
          floatingPL >= 0 ? C_GREEN : C_RED);
   HudSet("T4V", IntegerToString(g_dayEntries), C_TEXT);
   HudSet("T9V", (g_totalCollectedPL >= 0 ? "+" : "") + DoubleToString(g_totalCollectedPL, 2), g_totalCollectedPL >= 0 ? C_GREEN : C_RED);
   HudSet("T10V", IntegerToString(g_accountPositions), C_TEXT);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   HudSet("T5V", DoubleToString(balance, 2), C_TEXT);
   HudSet("T6V", DoubleToString(equity, 2), equity >= balance ? C_GREEN : C_RED);
   // --- Market intelligence telemetry
   HudSet("REGIMEV", g_marketRegime,
          StringFind(g_marketRegime, "EXPANSION") >= 0 ? C_AMBER :
          (StringFind(g_marketRegime, "TREND") >= 0 ? C_GREEN : C_CYAN));
   HudSet("MOMV", DoubleToString(g_marketMomentumATR, 2) + " ATR",
          g_marketMomentumATR >= 0 ? C_GREEN : C_RED);
   HudSet("VOLV", "x" + DoubleToString(g_atrRegimeRatio, 2),
          (g_atrRegimeRatio >= InpMinATRRegimeRatio && g_atrRegimeRatio <= InpMaxATRRegimeRatio) ? C_TEXT : C_RED);
   HudSet("INTELV", "B " + IntegerToString(g_intelScoreBull) + " / S " + IntegerToString(g_intelScoreBear),
          MathMax(g_intelScoreBull, g_intelScoreBear) >= InpMinIntelScore ? C_GREEN : C_AMBER);

   // --- DECISION TRACE: explain the current SMC/ICT analysis state.
   // Line 1 reports the latest decision reason; line 2 reports the
   // structures reached by the setup pipeline and the liquidity map.
   string cur = blink ? "_" : " ";
   string r1 = StringSubstr(g_reason, 0, 39);
   string stageName = "NO SETUP";
   int activeStage = MathMax(g_bull.stage, g_bear.stage);
   if(activeStage == 1) stageName = "SWEEP";
   else if(activeStage == 2) stageName = "MSS / DISPLACEMENT";
   else if(activeStage == 3) stageName = "FVG ZONE";
   else if(activeStage == 4) stageName = "PREMIUM/DISCOUNT";
   else if(activeStage >= 5) stageName = "CONFIRMED SETUP";

   string line2 = StringFormat("> %s | BSL:%d SSL:%d%s",
                               stageName, ArraySize(g_sweepHighs),
                               ArraySize(g_sweepLows), cur);
   if(StringLen(line2) > 47)
      line2 = StringSubstr(line2, 0, 46) + cur;
   HudSet("CL1", "> " + r1 + cur,
          StringFind(g_status, "REJECTED") >= 0 ? C_RED :
          (StringFind(g_status, "DETECTED") >= 0 ? C_GREEN : C_CYAN));
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
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

   // Entry zone (ICT FVG zone)
   datetime t2 = TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 12);
   string zn = "TRS_Z_ZONE" + tag;
   if(ObjectCreate(0, zn, OBJ_RECTANGLE, 0, s.zoneT, s.zoneHi, t2, s.zoneLo))
   {
      ObjectSetInteger(0, zn, OBJPROP_COLOR, cz);
      ObjectSetInteger(0, zn, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, zn, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zn, OBJPROP_FILL, false);
      ObjectSetInteger(0, zn, OBJPROP_BACK, true);
      ObjectSetInteger(0, zn, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, zn, OBJPROP_HIDDEN, true);
   }
   DrawText("TRS_Z_ZT" + tag, s.zoneT, bull ? s.zoneLo : s.zoneHi,
            "ICT FVG", cz, bull ? ANCHOR_UPPER : ANCHOR_LOWER);
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

// Draw every liquidity/structure level discovered by the current SMC/ICT scan.
// These are analysis annotations only; they do not place or manage orders.
void DrawLevelAnnotation(string name, datetime t, double price, string label, color clr, ENUM_LINE_STYLE style)
{
   string lineName = "TRS_LQ_L_" + name;
   string textName = "TRS_LQ_T_" + name;
   datetime t2 = TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 30);
   if(ObjectFind(0, lineName) < 0)
      ObjectCreate(0, lineName, OBJ_TREND, 0, t, price, t2, price);
   else
   {
      ObjectMove(0, lineName, 0, t, price);
      ObjectMove(0, lineName, 1, t2, price);
   }
   ObjectSetInteger(0, lineName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, style);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, (StringFind(name, "TARGET_") >= 0 ? 2 : 1));
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT, true);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);

   // A small coloured marker makes the exact origin of each detected level
   // visible, in addition to the extended horizontal line and text label.
   string markerName = "TRS_LQ_M_" + name;
   if(ObjectFind(0, markerName) < 0)
      ObjectCreate(0, markerName, OBJ_ARROW, 0, t, price);
   else ObjectMove(0, markerName, 0, t, price);
   ObjectSetInteger(0, markerName, OBJPROP_ARROWCODE, 159); // small circle
   ObjectSetInteger(0, markerName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, markerName, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, markerName, OBJPROP_BACK, false);
   ObjectSetInteger(0, markerName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, markerName, OBJPROP_HIDDEN, true);

   if(ObjectFind(0, textName) < 0)
      ObjectCreate(0, textName, OBJ_TEXT, 0, t2, price);
   else ObjectMove(0, textName, 0, t2, price);
   ObjectSetString(0, textName, OBJPROP_TEXT, label);
   ObjectSetString(0, textName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, textName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, textName, OBJPROP_BACK, false);
   ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, textName, OBJPROP_HIDDEN, true);
}

// Return false once a liquidity level has been swept after its origin time.
// High-side liquidity is invalidated by a later high through the level;
// low-side liquidity is invalidated by a later low through the level.
bool IsLiquidityLevelActive(datetime origin, double price, bool highSide)
{
   if(origin <= 0 || price <= 0) return false;
   MqlRates bars[];
   ArraySetAsSeries(bars, true);
   int copied = CopyRates(_Symbol, InpExecTF, 0, InpScanBars, bars);
   if(copied <= 0) return true; // retain if history is temporarily unavailable
   for(int k=1; k<copied; k++)
   {
      if(bars[k].time < origin) break;
      if(highSide && bars[k].high > price) return false;
      if(!highSide && bars[k].low < price) return false;
   }
   // Include live price so a level disappears immediately when swept.
   double live = highSide ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                          : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(highSide && live > price) return false;
   if(!highSide && live < price) return false;
   return true;
}

// A bullish FVG is no longer active after price fully fills its lower edge;
// a bearish FVG is no longer active after price fully fills its upper edge.
bool IsFVGActive(const MqlRates &rates[], int formationIndex, bool bullish,
                 double zoneLow, double zoneHigh)
{
   int n = ArraySize(rates);
   if(formationIndex < 1 || formationIndex+2 >= n || zoneHigh <= zoneLow) return false;
   // Only candles newer than the FVG's formation candle can invalidate it.
   for(int k=formationIndex-1; k>=1; k--)
   {
      if(bullish && rates[k].low <= zoneLow) return false;
      if(!bullish && rates[k].high >= zoneHigh) return false;
   }
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bullish && bid <= zoneLow) return false;
   if(!bullish && ask >= zoneHigh) return false;
   return true;
}

void DrawAllDetectedFVGs(const MqlRates &rates[], double atr)
{
   // Keep the most recent 20 bullish and 20 bearish three-candle FVGs visible.
   // rates[] is series-indexed: [0] is the current candle.
   ObjectsDeleteAll(0, "TRS_FVG_");
   int n=ArraySize(rates), bullCount=0, bearCount=0;
   if(n<3 || atr<=0) return;
   for(int i=1; i<n-2; i++)
   {
      // Bullish FVG: candle i+2 high remains below candle i low.
      double bullLo=rates[i+2].high, bullHi=rates[i].low;
      if(bullHi>bullLo && bullHi-bullLo>=InpMinFVGATR*atr && bullCount<20 &&
         IsFVGActive(rates, i, true, bullLo, bullHi))
      {
         string id="TRS_FVG_B_"+IntegerToString(bullCount++);
         datetime t1=rates[i+2].time;
         datetime t2=TimeCurrent()+(datetime)(PeriodSeconds(PERIOD_CURRENT)*20);
         if(ObjectCreate(0,id,OBJ_RECTANGLE,0,t1,bullHi,t2,bullLo))
         {
            ObjectSetInteger(0,id,OBJPROP_COLOR,C'0,210,140');
            ObjectSetInteger(0,id,OBJPROP_STYLE,STYLE_SOLID);
            ObjectSetInteger(0,id,OBJPROP_WIDTH,1);
            ObjectSetInteger(0,id,OBJPROP_FILL,false);
            ObjectSetInteger(0,id,OBJPROP_BACK,true);
            ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,id,OBJPROP_HIDDEN,true);
         }
         DrawText(id+"_TXT",t2,bullHi,"FVG +",C'0,210,140',ANCHOR_LEFT_LOWER);
      }
      // Bearish FVG: candle i+2 low remains above candle i high.
      double bearLo=rates[i].high, bearHi=rates[i+2].low;
      if(bearHi>bearLo && bearHi-bearLo>=InpMinFVGATR*atr && bearCount<20 &&
         IsFVGActive(rates, i, false, bearLo, bearHi))
      {
         string id="TRS_FVG_S_"+IntegerToString(bearCount++);
         datetime t1=rates[i+2].time;
         datetime t2=TimeCurrent()+(datetime)(PeriodSeconds(PERIOD_CURRENT)*20);
         if(ObjectCreate(0,id,OBJ_RECTANGLE,0,t1,bearHi,t2,bearLo))
         {
            ObjectSetInteger(0,id,OBJPROP_COLOR,C'255,70,90');
            ObjectSetInteger(0,id,OBJPROP_STYLE,STYLE_SOLID);
            ObjectSetInteger(0,id,OBJPROP_WIDTH,1);
            ObjectSetInteger(0,id,OBJPROP_FILL,false);
            ObjectSetInteger(0,id,OBJPROP_BACK,true);
            ObjectSetInteger(0,id,OBJPROP_SELECTABLE,false);
            ObjectSetInteger(0,id,OBJPROP_HIDDEN,true);
         }
         DrawText(id+"_TXT",t2,bearLo,"FVG -",C'255,70,90',ANCHOR_LEFT_UPPER);
      }
      if(bullCount>=20 && bearCount>=20) break;
   }
}

// Draw outlined price-range shapes for premium/discount zones. These are
// visual analysis guides only and never trigger or manage a trade.
void DrawRangeShape(string name, datetime t1, datetime t2, double top, double bottom,
                    color clr, string label)
{
   if(top <= bottom || t1 <= 0 || t2 <= t1) return;
   string boxName = "TRS_RANGE_BOX_" + name;
   if(ObjectFind(0, boxName) < 0)
      ObjectCreate(0, boxName, OBJ_RECTANGLE, 0, t1, top, t2, bottom);
   else
   {
      ObjectMove(0, boxName, 0, t1, top);
      ObjectMove(0, boxName, 1, t2, bottom);
   }
   ObjectSetInteger(0, boxName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, boxName, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, boxName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, boxName, OBJPROP_FILL, false);
   ObjectSetInteger(0, boxName, OBJPROP_BACK, true);
   ObjectSetInteger(0, boxName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, boxName, OBJPROP_HIDDEN, true);
   DrawText(boxName + "_TXT", t2, top, label, clr, ANCHOR_LEFT_LOWER);
}

void DrawDetectedStructures()
{
   if(!InpDrawZones) return;
   ObjectsDeleteAll(0, "TRS_LQ_");
   ObjectsDeleteAll(0, "TRS_RANGE_BOX_");
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int count = 0;
   // Every identified buy-side/sell-side liquidity level (swing, PDH/PDL,
   // Asian range and higher-timeframe levels added by BuildLiquidity).
   for(int i=0; i<ArraySize(g_sweepHighs); i++)
   {
      if(!IsLiquidityLevelActive(g_sweepHighs[i].t, g_sweepHighs[i].p, true)) continue;
      string id = "BSL_" + IntegerToString(count++);
      DrawLevelAnnotation(id, g_sweepHighs[i].t, g_sweepHighs[i].p,
                          "BSL  " + DoubleToString(g_sweepHighs[i].p,dg), C'255,90,110', STYLE_DASH);
   }
   count = 0;
   for(int i=0; i<ArraySize(g_sweepLows); i++)
   {
      if(!IsLiquidityLevelActive(g_sweepLows[i].t, g_sweepLows[i].p, false)) continue;
      string id = "SSL_" + IntegerToString(count++);
      DrawLevelAnnotation(id, g_sweepLows[i].t, g_sweepLows[i].p,
                          "SSL  " + DoubleToString(g_sweepLows[i].p,dg), C'0,220,170', STYLE_DASH);
   }
   count = 0;
   for(int i=0; i<ArraySize(g_tgtHighs); i++)
   {
      if(!IsLiquidityLevelActive(g_tgtHighs[i].t, g_tgtHighs[i].p, true)) continue;
      string id = "TARGET_HIGH_" + IntegerToString(count++);
      DrawLevelAnnotation(id, g_tgtHighs[i].t, g_tgtHighs[i].p,
                          "HTF BSL  " + DoubleToString(g_tgtHighs[i].p,dg), C'180,90,220', STYLE_DOT);
   }
   count = 0;
   for(int i=0; i<ArraySize(g_tgtLows); i++)
   {
      if(!IsLiquidityLevelActive(g_tgtLows[i].t, g_tgtLows[i].p, false)) continue;
      string id = "TARGET_LOW_" + IntegerToString(count++);
      DrawLevelAnnotation(id, g_tgtLows[i].t, g_tgtLows[i].p,
                          "HTF SSL  " + DoubleToString(g_tgtLows[i].p,dg), C'180,90,220', STYLE_DOT);
   }
   // Current dealing range: premium, equilibrium and discount reference.
   if(g_eqValid && g_eq > 0)
   {
      double hi=0, lo=0;
      if(DealingRange(hi,lo) && hi>lo)
      {
         datetime now = TimeCurrent();
         DrawLevelAnnotation("PREMIUM", now, hi, "PREMIUM", C'255,140,80', STYLE_DOT);
         DrawLevelAnnotation("EQUILIBRIUM", now, g_eq, "EQ 50%", C'240,210,70', STYLE_DASHDOT);
         DrawLevelAnnotation("DISCOUNT", now, lo, "DISCOUNT", C'80,180,255', STYLE_DOT);

         datetime rangeStart = iTime(_Symbol, PERIOD_H1, 30);
         if(rangeStart <= 0) rangeStart = now - (datetime)(PeriodSeconds(PERIOD_CURRENT) * 100);
         datetime rangeEnd = now + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 30);
         DrawRangeShape("PREMIUM", rangeStart, rangeEnd, hi, g_eq, C'255,140,80', "PREMIUM ZONE");
         DrawRangeShape("DISCOUNT", rangeStart, rangeEnd, g_eq, lo, C'80,180,255', "DISCOUNT ZONE");
      }
   }
   ChartRedraw(0);
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
// Keep each detected overlay visible only on the timeframe that produced it.
// The current setup/liquidity/FVG drawing pipeline is fed by InpExecTF rates,
// so its objects are restricted to that source timeframe. HTF bias calculations
// continue independently and do not get disabled by this visual filter.
void ApplySourceTimeframeDrawingVisibility()
{
   long timeframeMask = 0;
   switch(InpExecTF)
   {
      case PERIOD_M1:  timeframeMask = OBJ_PERIOD_M1;  break;
      case PERIOD_M2:  timeframeMask = OBJ_PERIOD_M2;  break;
      case PERIOD_M3:  timeframeMask = OBJ_PERIOD_M3;  break;
      case PERIOD_M4:  timeframeMask = OBJ_PERIOD_M4;  break;
      case PERIOD_M5:  timeframeMask = OBJ_PERIOD_M5;  break;
      case PERIOD_M6:  timeframeMask = OBJ_PERIOD_M6;  break;
      case PERIOD_M10: timeframeMask = OBJ_PERIOD_M10; break;
      case PERIOD_M12: timeframeMask = OBJ_PERIOD_M12; break;
      case PERIOD_M15: timeframeMask = OBJ_PERIOD_M15; break;
      case PERIOD_M20: timeframeMask = OBJ_PERIOD_M20; break;
      case PERIOD_M30: timeframeMask = OBJ_PERIOD_M30; break;
      case PERIOD_H1:  timeframeMask = OBJ_PERIOD_H1;  break;
      case PERIOD_H2:  timeframeMask = OBJ_PERIOD_H2;  break;
      case PERIOD_H3:  timeframeMask = OBJ_PERIOD_H3;  break;
      case PERIOD_H4:  timeframeMask = OBJ_PERIOD_H4;  break;
      case PERIOD_H6:  timeframeMask = OBJ_PERIOD_H6;  break;
      case PERIOD_H8:  timeframeMask = OBJ_PERIOD_H8;  break;
      case PERIOD_H12: timeframeMask = OBJ_PERIOD_H12; break;
      case PERIOD_D1:  timeframeMask = OBJ_PERIOD_D1;  break;
      case PERIOD_W1:  timeframeMask = OBJ_PERIOD_W1;  break;
      case PERIOD_MN1: timeframeMask = OBJ_PERIOD_MN1; break;
      default:         timeframeMask = OBJ_PERIOD_M5;  break;
   }

   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "TRS_Z_") == 0 ||
         StringFind(name, "TRS_LQ_") == 0 ||
         StringFind(name, "TRS_FVG_") == 0 ||
         StringFind(name, "TRS_RANGE_BOX_") == 0)
      {
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, timeframeMask);
      }
   }
}

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

   datetime m30Bar = iTime(_Symbol, PERIOD_M30, 0);
   if(m30Bar == 0) return false;
   if(m30Bar != g_lastM30Bar)
   {
      int m30Bias = 0;
      if(!HtfBias(PERIOD_M30, m30Bias)) return false;
      g_cachedM30Bias = m30Bias;
      g_lastM30Bar = m30Bar;
   }

   datetime m15Bar = iTime(_Symbol, PERIOD_M15, 0);
   if(m15Bar == 0) return false;
   if(m15Bar != g_lastM15Bar)
   {
      int m15Bias = 0;
      if(!HtfBias(PERIOD_M15, m15Bias)) return false;
      g_cachedM15Bias = m15Bias;
      g_lastM15Bar = m15Bar;
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
   if(atr <= 0.0 || !UpdateMarketIntelligence(r, atr)) return false;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(atr <= 0 || ask <= 0 || bid <= 0) return false;

   FindSetup(true,  r, atr, g_eqValid, g_eq, ask, bid, g_bull, g_noteBull);
   FindSetup(false, r, atr, g_eqValid, g_eq, ask, bid, g_bear, g_noteBear);

   g_lastExec  = t;
   g_execReady = true;

   DrawDetectedStructures();
   DrawAllDetectedFVGs(r, atr);
   DrawSetupOverlays();
   ApplySourceTimeframeDrawingVisibility();
   return true;
}

//=========================== TICK ENGINE ============================//
void FastTickEngine()
{
   if(!g_analysisRunning) return;
   if(GetTickCount() < g_startAtMs) { g_status = "INITIALISING"; return; }
   if(g_rejectUntilMs > 0 && GetTickCount() < g_rejectUntilMs) { g_status = "SIGNAL REJECTED"; return; }
   if(g_rejectUntilMs > 0 && GetTickCount() >= g_rejectUntilMs) { g_rejectUntilMs = 0; g_status = "SCANNING"; }
   bool ready = RefreshExec();
   g_inKZ = InKillZone();

   // Continue scanning while positions/orders are active; InpMaxActive controls the cap (0 = unlimited).

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
      string wmsg = "Treasure v3.6: running on reduced history after " +
                    IntegerToString(InpMaxWarmupSeconds) + "s warm-up - signals may be less reliable until full history backfills.";
      Print(wmsg);
      if(InpAlertOnTrade) Alert(wmsg);
      g_reducedNotified = true;
   }

   // Analysis-only: never place, modify, or close trades.
   if(g_bull.stage < 5 && g_bear.stage < 5 && g_signalWasDetected)
   {
      g_signalWasDetected = false;
      g_rejectUntilMs = GetTickCount() + 5000;
      g_status = "SIGNAL REJECTED";
      g_reason = "Previously detected setup is no longer valid; resuming scan in 5 seconds.";
      return;
   }
   if(g_bull.stage == 5 || g_bear.stage == 5)
   {
      Setup sig = (g_bull.stage == 5 && (g_bear.stage != 5 || g_bull.key >= g_bear.key)) ? g_bull : g_bear;
      string side = (g_bull.stage == 5 && (g_bear.stage != 5 || g_bull.key >= g_bear.key)) ? "BUY" : "SELL";
      if(sig.key != g_lastDisplayedSignal)
      {
         g_lastDisplayedSignal = sig.key;
         g_lastSignal = side + " SETUP";
         g_status = "SIGNAL DETECTED";
         g_signalWasDetected = true;
         g_reason = side + " SMC/ICT setup detected. Review chart markings before trading manually.";
      }
      return;
   }

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

// Persist running state across MT5 chart-timeframe reinitialization.
string RunningStateKey()
{
   return "TREASURE36_RUN_" + IntegerToString(ChartID()) + "_" +
          IntegerToString(InpMagicNumber);
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
      InpMinRR <= 0 || InpMaxActive < 0 ||
      InpRiskPercent < 0 || InpMaxDailyLossR < 0 ||
      InpPartialPercent <= 0 || InpPartialPercent >= 100 ||
      InpMinSignalScore < 0 || InpMinSignalScore > 100 ||
      InpMinIntelScore < 0 || InpMinIntelScore > 100 ||
      InpIntelLookback < 4 || InpIntelLookback > 50 ||
      InpMinATRRegimeRatio <= 0 || InpMaxATRRegimeRatio <= InpMinATRRegimeRatio ||
      PeriodSeconds(InpExecTF) > 3600 || PeriodSeconds(InpExecTF) < 60)
   {
      Print("Treasure v3.6: invalid input parameters (setup TF must be M1..H1)");
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
   g_cachedM30Bias = 0;
   g_cachedM15Bias = 0;
   g_lastM30Bar = 0;
   g_lastM15Bar = 0;
   g_tick = 0;
   g_initMs = GetTickCount();
   g_reducedHistory = false;
   g_reducedNotified = false;

   ArrayResize(g_sweepLows, 0);
   ArrayResize(g_sweepHighs, 0);
   ArrayResize(g_tgtHighs, 0);
   ArrayResize(g_tgtLows, 0);

   g_signalWasDetected = false;
   string runKey = RunningStateKey();
   bool resumeAnalysis = GlobalVariableCheck(runKey) && GlobalVariableGet(runKey) > 0.5;
   g_analysisRunning = resumeAnalysis;
   if(resumeAnalysis)
   {
      g_startAtMs = GetTickCount(); // Resume immediately after timeframe change.
      g_rejectUntilMs = 0;
      g_status = "SCANNING";
      g_reason = "Analysis resumed after chart/timeframe change.";
   }
   else
   {
      g_status = "STOPPED";
      g_reason = "Press START ANALYSIS to begin SMC/ICT market scanning.";
   }

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

      EventSetMillisecondTimer(250);
      ChartRedraw(0);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   string runKey = RunningStateKey();
   if(reason == REASON_CHARTCHANGE)
   {
      // Keep the running state and chart overlays so OnInit can resume after a
      // timeframe/symbol chart change without requiring another button click.
      GlobalVariableSet(runKey, g_analysisRunning ? 1.0 : 0.0);
      // Restore original chart appearance before MT5 calls OnInit again.
      RestoreTheme();
      if(g_descrChanged)
      {
         ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, g_descrSaved);
         g_descrChanged = false;
      }
   }
   else
   {
      // Removing/recompiling/changing inputs should not leave a stale "running" flag.
      GlobalVariableSet(runKey, 0.0);
      ObjectsDeleteAll(0, HUD);   // HUD plus Treasure overlays/lines
      RestoreTheme();
      if(g_descrChanged)
      {
         ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, g_descrSaved);
         g_descrChanged = false;
      }
   }
   ChartRedraw(0);
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == HUD + "RUNBTN")
   {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      if(!g_analysisRunning)
      {
         g_analysisRunning = true; g_startAtMs = GetTickCount() + 10000; g_rejectUntilMs = 0;
         GlobalVariableSet(RunningStateKey(), 1.0);
         g_status = "INITIALISING"; g_reason = "Initialising market data and SMC/ICT analysis for 10 seconds.";
         HudSet("RUNBTN", "RUNNING - INITIALISING", C_AMBER);
      }
      else
      {
         g_analysisRunning = false; GlobalVariableSet(RunningStateKey(), 0.0);
         g_status = "STOPPED"; g_reason = "Analysis stopped by trader.";
         HudSet("RUNBTN", "START ANALYSIS", C_CYAN);
      }
      ChartRedraw(0); return;
   }
   if(sparam != HUD + "MINBTN") return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   if(g_hudMinimized)
   {
      g_hudMinimized = false;
      if(InpShowDashboard) BuildHud();
   }
   else
   {
      g_hudMinimized = true;
      BuildMinimizedHud();
   }
   ChartRedraw(0);
}

void OnTimer()
{
   if(!HudActive()) return;

   g_tick++;
   if(g_analysisRunning)
   {
      if(GetTickCount() < g_startAtMs) g_status = "INITIALISING";
      else if(g_rejectUntilMs == 0 || GetTickCount() >= g_rejectUntilMs)
      {
         g_rejectUntilMs = 0;
         FastTickEngine();
      }
   }
   if(InpShowDashboard && !g_hudMinimized)
   {
      UpdateHud();
      HudSet("RUNBTN", g_analysisRunning ? "STOP ANALYSIS" : "START ANALYSIS", g_analysisRunning ? C_RED : C_CYAN);
   }

   ChartRedraw(0);
}

void OnTick()
{
   // Analysis is scheduled by the timer only after the trader presses START.
}
//+------------------------------------------------------------------+
