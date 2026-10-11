//+------------------------------------------------------------------+
//|                    TREASURE EA v2.3                              |
//| Swing + SMC + Clean Sniper Confirmation | Target R:R 1:5         |
//|                                                                  |
//| v2.3: sci-fi "AI CORE" HUD for desktop MT5 charts                |
//|  - neon panel built from chart objects (no Comment() text)       |
//|  - status badge, pulse LED, scan line, neural-node LED grid,     |
//|    confluence energy bar, telemetry, AI console, data stream     |
//|  - FVG / order-block zones drawn on the chart                    |
//|  - entry / SL / TP lines for the EA's open position              |
//|  - optional dark neon chart theme (restored on removal)          |
//| Trading logic is identical to v2.2.                              |
//+------------------------------------------------------------------+
#property version   "2.30"
#property description "Treasure EA v2.3 - Swing + SMC + Sniper Entry + AI HUD"

#include <Trade/Trade.mqh>
CTrade trade;

//============================== INPUTS ==============================//
input group "Trade"
input double InpLots                  = 0.01;   // Fixed lots (used only when Risk % = 0)
input double InpRiskPercent           = 0.5;    // Risk per trade, % of balance (0 = fixed lots)
input long   InpMagicNumber           = 21001;
input double InpRiskReward            = 5.0;
input int    InpSLBufferPoints        = 20;
input int    InpMaxSLPoints           = 1500;   // Reject setups with wider SL (0 = off)
input int    InpMaxPositions          = 1;      // Max open positions for this symbol + magic

input group "Limits"
input double InpMaxDailyLossPercent   = 3.0;    // Stop trading for the day (0 = off)
input int    InpMaxTradesPerDay       = 3;      // 0 = off
input int    InpCooldownMinutes       = 15;     // Min minutes between entries (0 = off)
input int    InpMaxSpreadPoints       = 40;

input group "Session"
input bool   InpUseSessionFilter      = false;
input int    InpSessionStartHour      = 7;
input int    InpSessionEndHour        = 22;
input bool   InpSessionUseLocalTime   = false;  // false = broker server time

input group "Signal"
input int    InpSwingLookback         = 5;      // 1..9
input int    InpLiquidityLookback     = 20;
input int    InpFVGLookback           = 30;
input int    InpOBLookback            = 20;
input int    InpMinConfluenceScore    = 7;      // out of 8

input group "AI HUD"
input bool   InpShowDashboard         = true;   // Sci-fi HUD panel
input int    InpPanelX                = 15;     // Panel X (pixels from left)
input int    InpPanelY                = 30;     // Panel Y (pixels from top)
input bool   InpDrawZones             = true;   // Draw FVG / OB zones on chart
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
struct Analysis
{
   bool bullishTrend;
   bool bearishTrend;
   bool liquidityBull;
   bool liquidityBear;
   bool bosBull;
   bool bosBear;
   bool chochBull;
   bool chochBear;
   bool fvgBull;
   bool fvgBear;
   bool obBull;
   bool obBear;
   bool pdBull;
   bool pdBear;
   bool m15Bull;
   bool m15Bear;
   bool m5Bull;
   bool m5Bear;
   double entry;
   double sl;
   double tp;
   int score;
};

struct Zone
{
   double   lo;
   double   hi;
   datetime t;     // time of the first candle of the pattern (for drawing)
};

//============================== GLOBALS =============================//
string   g_lastSignal = "NONE";
string   g_status     = "STARTING";
string   g_reason     = "";

Analysis g_cache;

Zone     g_fvgBullZ[];
Zone     g_fvgBearZ[];
Zone     g_obBullZ[];
Zone     g_obBearZ[];
double   g_pdMid = 0.0;

bool     g_htfReady = false;
bool     g_m15Ready = false;
bool     g_m5Ready  = false;

datetime g_lastH1  = 0;
datetime g_lastH4  = 0;
datetime g_lastM15 = 0;
datetime g_lastM5  = 0;

datetime g_lastAttemptBar = 0;   // M5 bar on which an entry was last attempted
datetime g_lastTradeTime  = 0;   // server time of last successful entry

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

double RangeHigh(const MqlRates &r[], int start, int count)
{
   double h = -DBL_MAX;
   for(int i = start; i < start + count && i < ArraySize(r); i++)
      if(r[i].high > h) h = r[i].high;
   return h;
}

double RangeLow(const MqlRates &r[], int start, int count)
{
   double l = DBL_MAX;
   for(int i = start; i < start + count && i < ArraySize(r); i++)
      if(r[i].low < l) l = r[i].low;
   return l;
}

void AddZone(Zone &arr[], double lo, double hi, datetime t)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].lo = lo;
   arr[n].hi = hi;
   arr[n].t  = t;
}

bool InZones(const Zone &arr[], double price)
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(price >= arr[i].lo && price <= arr[i].hi) return true;
   return false;
}

bool SpreadOK()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = PointValue();
   if(point <= 0) return false;
   double spread = (ask - bid) / point;
   return spread <= InpMaxSpreadPoints;
}

bool SessionOK()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime tm;
   TimeToStruct(InpSessionUseLocalTime ? TimeLocal() : TimeCurrent(), tm);
   if(InpSessionStartHour <= InpSessionEndHour)
      return tm.hour >= InpSessionStartHour && tm.hour < InpSessionEndHour;
   return tm.hour >= InpSessionStartHour || tm.hour < InpSessionEndHour;
}

// Positions opened by THIS EA on THIS symbol (symbol + magic filter).
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

// Realised P/L (incl. commission, swap, fees) and entry count for today
// (broker server day), for deals carrying this EA's magic number.
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

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
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

//========================== SWING ANALYSIS ==========================//
bool DetectSwingTrend(Analysis &a)
{
   a.bullishTrend = false;
   a.bearishTrend = false;

   MqlRates r[];
   if(!GetRates(PERIOD_H1, 80, r)) return false;

   // H4 is mandatory: if its data is missing we retry instead of skipping it.
   MqlRates h4[];
   if(!GetRates(PERIOD_H4, 40, h4)) return false;

   double recentHigh = RangeHigh(r, 1, InpSwingLookback);
   double recentLow  = RangeLow(r, 1, InpSwingLookback);
   double oldHigh    = RangeHigh(r, 10, InpSwingLookback);
   double oldLow     = RangeLow(r, 10, InpSwingLookback);

   bool h1Bull = (recentHigh > oldHigh && recentLow > oldLow);
   bool h1Bear = (recentHigh < oldHigh && recentLow < oldLow);

   double h4HighRecent = RangeHigh(h4, 1, 3);
   double h4LowRecent  = RangeLow(h4, 1, 3);
   double h4HighOld    = RangeHigh(h4, 8, 3);
   double h4LowOld     = RangeLow(h4, 8, 3);

   bool h4Bull = h4HighRecent > h4HighOld && h4LowRecent > h4LowOld;
   bool h4Bear = h4HighRecent < h4HighOld && h4LowRecent < h4LowOld;

   a.bullishTrend = h1Bull && h4Bull;
   a.bearishTrend = h1Bear && h4Bear;
   return true;
}

// Midpoint of the last 30 closed H1 bars (premium / discount reference).
bool UpdatePDRange()
{
   MqlRates r[];
   if(!GetRates(PERIOD_H1, 32, r)) return false;

   double hi = RangeHigh(r, 1, 30);
   double lo = RangeLow(r, 1, 30);
   if(hi <= lo) return false;

   g_pdMid = (hi + lo) / 2.0;
   return true;
}

//=========================== LIQUIDITY ==============================//
bool DetectLiquidity(Analysis &a)
{
   a.liquidityBull = false;
   a.liquidityBear = false;

   MqlRates r[];
   if(!GetRates(PERIOD_M15, InpLiquidityLookback + 10, r)) return false;

   // Prior range = bars 2.. (bar 1 is the candle that may sweep it).
   double priorHigh = RangeHigh(r, 2, InpLiquidityLookback);
   double priorLow  = RangeLow(r, 2, InpLiquidityLookback);

   // Sweep + close back inside the prior range.
   a.liquidityBull = (r[1].low < priorLow && r[1].close > priorLow);
   a.liquidityBear = (r[1].high > priorHigh && r[1].close < priorHigh);
   return true;
}

//========================== BOS / CHOCH =============================//
bool DetectStructure(Analysis &a)
{
   a.bosBull   = false;
   a.bosBear   = false;
   a.chochBull = false;
   a.chochBear = false;

   MqlRates r[];
   if(!GetRates(PERIOD_M15, 50, r)) return false;

   double c = r[1].close;

   // BOS: close beyond the full 12-bar range (bars 2..13).
   double hh = RangeHigh(r, 2, 12);
   double ll = RangeLow(r, 2, 12);

   // Micro-trend: recent half (bars 2..7) vs older half (bars 8..13).
   double recHH = RangeHigh(r, 2, 6);
   double recLL = RangeLow(r, 2, 6);
   double oldHH = RangeHigh(r, 8, 6);
   double oldLL = RangeLow(r, 8, 6);

   bool microDown = (recHH < oldHH && recLL < oldLL);
   bool microUp   = (recHH > oldHH && recLL > oldLL);

   a.bosBull = c > hh;
   a.bosBear = c < ll;

   // CHoCH: micro-trend flips - close breaks the most recent lower high
   // (after lower highs/lows) or the most recent higher low (after higher
   // highs/lows).
   a.chochBull = microDown && c > recHH;
   a.chochBear = microUp   && c < recLL;
   return true;
}

//============================== FVG =================================//
// Collects every bullish / bearish 3-candle imbalance as a price range.
// Whether price is inside one is tested live (UpdateLiveFlags).
bool ScanFVG()
{
   ArrayResize(g_fvgBullZ, 0);
   ArrayResize(g_fvgBearZ, 0);

   MqlRates r[];
   if(!GetRates(PERIOD_M15, InpFVGLookback + 5, r)) return false;

   // r[i+2] oldest, r[i+1] middle, r[i] newest candle of the pattern.
   for(int i = 1; i < InpFVGLookback && i + 2 < ArraySize(r); i++)
   {
      if(r[i + 2].high < r[i].low)
         AddZone(g_fvgBullZ, r[i + 2].high, r[i].low, r[i + 2].time);

      if(r[i + 2].low > r[i].high)
         AddZone(g_fvgBearZ, r[i].high, r[i + 2].low, r[i + 2].time);
   }
   return true;
}

//=========================== ORDER BLOCK ============================//
// Starts at bar 3 so that r[i-2] is the last CLOSED bar (no forming bar).
bool ScanOB()
{
   ArrayResize(g_obBullZ, 0);
   ArrayResize(g_obBearZ, 0);

   MqlRates r[];
   if(!GetRates(PERIOD_M15, InpOBLookback + 8, r)) return false;

   for(int i = 3; i < InpOBLookback && i < ArraySize(r); i++)
   {
      double body  = MathAbs(r[i].close - r[i].open);
      double range = r[i].high - r[i].low;
      if(range <= 0) continue;
      if(body / range <= 0.45) continue;

      // Bullish displacement after a bearish candle.
      if(r[i].close < r[i].open &&
         (r[i - 1].close > r[i].high || r[i - 2].close > r[i].high))
         AddZone(g_obBullZ, r[i].low, r[i].high, r[i].time);

      // Bearish displacement after a bullish candle.
      if(r[i].close > r[i].open &&
         (r[i - 1].close < r[i].low || r[i - 2].close < r[i].low))
         AddZone(g_obBearZ, r[i].low, r[i].high, r[i].time);
   }
   return true;
}

//======================= LIVE PRICE-DEPENDENT FLAGS =================//
// Rebuilt from scratch on every call, so nothing can stay "stuck" true.
bool UpdateLiveFlags(Analysis &a)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;

   // Buys enter at ask, sells at bid.
   a.fvgBull = InZones(g_fvgBullZ, ask);
   a.obBull  = InZones(g_obBullZ,  ask);
   a.fvgBear = InZones(g_fvgBearZ, bid);
   a.obBear  = InZones(g_obBearZ,  bid);

   double mid = (ask + bid) / 2.0;
   a.pdBull = (g_pdMid > 0 && mid < g_pdMid);
   a.pdBear = (g_pdMid > 0 && mid > g_pdMid);
   return true;
}

//========================= M15 CONFIRMATION =========================//
bool DetectM15Confirmation(Analysis &a)
{
   a.m15Bull = false;
   a.m15Bear = false;

   MqlRates r[];
   if(!GetRates(PERIOD_M15, 10, r)) return false;

   a.m15Bull = r[1].close > r[1].open &&
               r[1].close > r[2].close;

   a.m15Bear = r[1].close < r[1].open &&
               r[1].close < r[2].close;
   return true;
}

//========================== M5 SNIPER ===============================//
bool DetectM5Sniper(Analysis &a)
{
   a.m5Bull = false;
   a.m5Bear = false;

   MqlRates r[];
   if(!GetRates(PERIOD_M5, 10, r)) return false;

   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range <= 0) return true;   // flags stay false

   double bodyRatio = body / range;

   // Clean directional candle plus close beyond previous candle.
   a.m5Bull = r[1].close > r[1].open &&
              r[1].close > r[2].high &&
              bodyRatio >= 0.55;

   a.m5Bear = r[1].close < r[1].open &&
              r[1].close < r[2].low &&
              bodyRatio >= 0.55;
   return true;
}

//======================== CONFLUENCE SCORE ==========================//
void CalculateScore(Analysis &a)
{
   a.score = 0;

   if(a.bullishTrend || a.bearishTrend) a.score++;

   if((a.liquidityBull && a.bullishTrend) ||
      (a.liquidityBear && a.bearishTrend)) a.score++;

   if(((a.bosBull || a.chochBull) && a.bullishTrend) ||
      ((a.bosBear || a.chochBear) && a.bearishTrend)) a.score++;

   if((a.fvgBull && a.bullishTrend) || (a.fvgBear && a.bearishTrend)) a.score++;
   if((a.obBull  && a.bullishTrend) || (a.obBear  && a.bearishTrend)) a.score++;
   if((a.pdBull  && a.bullishTrend) || (a.pdBear  && a.bearishTrend)) a.score++;
   if((a.m15Bull && a.bullishTrend) || (a.m15Bear && a.bearishTrend)) a.score++;
   if((a.m5Bull  && a.bullishTrend) || (a.m5Bear  && a.bearishTrend)) a.score++;
}

bool BuySignal(const Analysis &a)
{
   return a.bullishTrend &&
          (a.liquidityBull || a.chochBull || a.bosBull) &&
          (a.fvgBull || a.obBull) &&
          a.m15Bull &&
          a.m5Bull;
}

bool SellSignal(const Analysis &a)
{
   return a.bearishTrend &&
          (a.liquidityBear || a.chochBear || a.bosBear) &&
          (a.fvgBear || a.obBear) &&
          a.m15Bear &&
          a.m5Bear;
}

//====================== R:R / SL / TP CHECK =========================//
bool BuildTradeLevels(Analysis &a, bool buy)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = PointValue();
   if(ask <= 0 || bid <= 0 || point <= 0)
   {
      g_reason = "No valid price";
      return false;
   }

   MqlRates r[];
   if(!GetRates(PERIOD_M5, 14, r))
   {
      g_reason = "M5 history not ready";
      return false;
   }

   double entry     = buy ? ask : bid;
   double swingLow  = RangeLow(r, 1, 12);
   double swingHigh = RangeHigh(r, 1, 12);
   double buffer    = InpSLBufferPoints * point;

   double sl = buy ? swingLow - buffer : swingHigh + buffer;
   if((buy && sl >= entry) || (!buy && sl <= entry))
   {
      g_reason = "SL on wrong side of entry";
      return false;
   }

   double risk = MathAbs(entry - sl);
   if(risk <= 0)
   {
      g_reason = "Zero risk distance";
      return false;
   }

   if(InpMaxSLPoints > 0 && risk / point > InpMaxSLPoints)
   {
      g_reason = "SL too wide (" + IntegerToString((int)(risk / point)) + " pts)";
      return false;
   }

   double tp = buy ? entry + risk * InpRiskReward
                   : entry - risk * InpRiskReward;

   // Broker stop-distance validation, measured from the price that
   // triggers the stops (bid for longs, ask for shorts).
   long   stops       = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stops * point;
   double ref         = buy ? bid : ask;

   if(MathAbs(ref - sl) < minDistance || MathAbs(tp - ref) < minDistance)
   {
      g_reason = "SL/TP inside broker stop level";
      return false;
   }

   a.entry = NormalizePrice(entry);
   a.sl    = NormalizePrice(sl);
   a.tp    = NormalizePrice(tp);
   return true;
}

//=========================== EXECUTION ==============================//
bool ExecuteSignal(Analysis &a, bool buy)
{
   // Mark this M5 bar as used no matter how the attempt ends, so a
   // rejection / failure / quick stop-out cannot cause a tick-by-tick retry.
   g_lastAttemptBar = iTime(_Symbol, PERIOD_M5, 0);

   if(CountMyPositions() >= InpMaxPositions)
   {
      g_reason = "Existing position on symbol";
      return false;
   }

   if(a.score < InpMinConfluenceScore)
   {
      g_reason = "Confluence score below minimum";
      return false;
   }

   if(InpMaxDailyLossPercent > 0 || InpMaxTradesPerDay > 0)
   {
      double pl = 0.0;
      int entries = 0;
      if(!TodayStats(pl, entries))
      {
         g_reason = "Deal history unavailable";
         return false;
      }

      if(InpMaxTradesPerDay > 0 && entries >= InpMaxTradesPerDay)
      {
         g_status = "WAITING";
         g_reason = "Daily trade limit reached";
         return false;
      }

      if(InpMaxDailyLossPercent > 0)
      {
         double limit = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxDailyLossPercent / 100.0;
         if(pl + FloatingPL() <= -limit)
         {
            g_status = "WAITING";
            g_reason = "Daily loss limit reached";
            return false;
         }
      }
   }

   if(!BuildTradeLevels(a, buy))
      return false;

   double lots = CalcLots(buy, a.entry, a.sl);
   if(lots <= 0.0)
      return false;

   double margin = 0.0;
   if(OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
                      _Symbol, lots, a.entry, margin) &&
      margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      g_reason = "Not enough free margin";
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);

   bool ok = false;
   if(buy)
      ok = trade.Buy(lots, _Symbol, 0.0, a.sl, a.tp, "TREASURE v2.3 BUY");
   else
      ok = trade.Sell(lots, _Symbol, 0.0, a.sl, a.tp, "TREASURE v2.3 SELL");

   if(ok)
   {
      g_lastSignal    = buy ? "BUY" : "SELL";
      g_lastTradeTime = TimeCurrent();
      g_status        = "EXECUTED";
      g_reason        = "Confirmed sniper signal";
      PrintFormat("Treasure v2.3 %s %.2f lots | SL %s | TP %s | score %d",
                  g_lastSignal, lots,
                  DoubleToString(a.sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  DoubleToString(a.tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  a.score);
      return true;
   }

   g_reason = "Order failed: " + trade.ResultRetcodeDescription();
   return false;
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
   if(s == "EXECUTED" || s == "SIGNAL CONFIRMED") return C_GREEN;
   if(s == "REJECTED")                            return C_RED;
   if(s == "WAITING")                             return C_AMBER;
   if(s == "ANALYSING")                           return C'120,200,255';
   if(s == "STARTING")                            return C_DIM;
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

string g_nodeNames[8] = {"TREND  H4/H1", "LIQUIDITY SWEEP", "BOS / CHoCH", "FAIR VALUE GAP",
                         "ORDER BLOCK", "PREM / DISCOUNT", "M15 CONFIRM", "M5 SNIPER"};

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
   HudLabel("SUB", 14, 42, "SMC NEURAL SCANNER  |  v2.3", C_DIM, 8);

   // Status badge
   HudRect("BADGE", 14, 62, HUD_W - 28, 26, C'6,26,42', C_CYAN);
   HudRect("PULSE", 24, 71, 8, 8, C_CYAN, C_CYAN);
   HudLabel("STATUS", HUD_W / 2, 67, "STARTING", C_CYAN, 10, ANCHOR_UPPER);

   // Market state
   HudSection("MKT", 100, "// MARKET STATE");
   HudLabel("BIASL", 14, 122, "H4/H1 BIAS", C_TEXT, 9);
   HudLabel("BIASV", HUD_W - 14, 120, "NEUTRAL", C_AMBER, 12, ANCHOR_RIGHT_UPPER);

   // Neural nodes
   HudSection("NODE", 152, "// NEURAL NODES");
   HudLabel("HB", 257, 152, "BULL", C_GREEN, 8, ANCHOR_UPPER);
   HudLabel("HR", 317, 152, "BEAR", C_RED, 8, ANCHOR_UPPER);
   for(int i = 0; i < 8; i++)
   {
      int y = 176 + i * 20;
      HudLabel("NN" + IntegerToString(i), 14, y, g_nodeNames[i], C_TEXT, 9);
      HudRect("LB" + IntegerToString(i), 252, y + 2, 10, 10, C_OFF, C_OFF);
      HudRect("LR" + IntegerToString(i), 312, y + 2, 10, 10, C_OFF, C_OFF);
   }

   // Confluence energy bar
   HudSection("CONF", 346, "// CONFLUENCE");
   HudLabel("SCORE", HUD_W - 14, 344, "0 / 8", C_CYAN, 10, ANCHOR_RIGHT_UPPER);
   for(int i = 0; i < 8; i++)
      HudRect("SEG" + IntegerToString(i), 14 + i * 42, 368, 38, 12, C_OFF, C_OFF);
   int mk = MathMax(1, MathMin(8, InpMinConfluenceScore)) - 1;
   HudLabel("MARK", 14 + mk * 42, 384, "^ MIN " + IntegerToString(InpMinConfluenceScore), C_AMBER, 8);

   // Telemetry
   HudSection("TEL", 406, "// TELEMETRY");
   HudLabel("T1L", 14, 428, "SPREAD", C_DIM, 9);
   HudLabel("T1V", 100, 428, "-", C_TEXT, 9);
   HudLabel("T2L", 196, 428, "POSITIONS", C_DIM, 9);
   HudLabel("T2V", 290, 428, "-", C_TEXT, 9);
   HudLabel("T3L", 14, 446, "DAY P/L", C_DIM, 9);
   HudLabel("T3V", 100, 446, "-", C_TEXT, 9);
   HudLabel("T4L", 196, 446, "TRADES", C_DIM, 9);
   HudLabel("T4V", 290, 446, "-", C_TEXT, 9);
   HudLabel("T5L", 14, 464, "LAST SIG", C_DIM, 9);
   HudLabel("T5V", 100, 464, "-", C_TEXT, 9);
   HudLabel("T6L", 196, 464, "TARGET R:R", C_DIM, 9);
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

   // Live price-dependent flags (zones, premium/discount) + score.
   if(g_htfReady && g_m15Ready && g_m5Ready)
   {
      UpdateLiveFlags(g_cache);
      CalculateScore(g_cache);
   }
   Analysis a = g_cache;

   if(g_tick % 40 == 1) RefreshDayStats();

   // --- status badge + pulse LED
   color sc = StatusColor(g_status);
   HudRectColor("BADGE", Dim(sc, 0.18), sc);
   HudRectColor("PULSE", blink ? sc : Dim(sc, 0.25), blink ? sc : Dim(sc, 0.25));
   HudSet("STATUS", "<< " + g_status + " >>", sc);

   // --- bias
   string bias = "NEUTRAL";
   color  bc   = C_AMBER;
   if(a.bullishTrend) { bias = "/\\ BULLISH"; bc = C_GREEN; }
   if(a.bearishTrend) { bias = "\\/ BEARISH"; bc = C_RED; }
   HudSet("BIASV", bias, bc);

   // --- neural nodes
   bool bull[8], bear[8];
   bull[0] = a.bullishTrend;                 bear[0] = a.bearishTrend;
   bull[1] = a.liquidityBull;                bear[1] = a.liquidityBear;
   bull[2] = a.bosBull || a.chochBull;       bear[2] = a.bosBear || a.chochBear;
   bull[3] = a.fvgBull;                      bear[3] = a.fvgBear;
   bull[4] = a.obBull;                       bear[4] = a.obBear;
   bull[5] = a.pdBull;                       bear[5] = a.pdBear;
   bull[6] = a.m15Bull;                      bear[6] = a.m15Bear;
   bull[7] = a.m5Bull;                       bear[7] = a.m5Bear;

   for(int i = 0; i < 8; i++)
   {
      string id = IntegerToString(i);
      HudRectColor("LB" + id, bull[i] ? C_GREEN : C_OFF, bull[i] ? C_GREEN : C_OFF);
      HudRectColor("LR" + id, bear[i] ? C_RED   : C_OFF, bear[i] ? C_RED   : C_OFF);
      ObjectSetInteger(0, HUD + "NN" + id, OBJPROP_COLOR,
                       (bull[i] || bear[i]) ? C'225,245,255' : C_TEXT);
   }

   // --- confluence bar
   color segOn = (a.score >= InpMinConfluenceScore) ? C_GREEN : C_CYAN;
   for(int i = 0; i < 8; i++)
   {
      color c = (i < a.score) ? segOn : C_OFF;
      HudRectColor("SEG" + IntegerToString(i), c, c);
   }
   HudSet("SCORE", IntegerToString(a.score) + " / 8", segOn);

   // --- telemetry
   double point  = PointValue();
   double spread = (point > 0) ? (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                                  SymbolInfoDouble(_Symbol, SYMBOL_BID)) / point : 0;
   HudSet("T1V", DoubleToString(spread, 0) + " pts",
          spread <= InpMaxSpreadPoints ? C_TEXT : C_RED);
   HudSet("T2V", IntegerToString(CountMyPositions()) + " / " + IntegerToString(InpMaxPositions), C_TEXT);
   HudSet("T3V", (g_dayPL >= 0 ? "+" : "") + DoubleToString(g_dayPL, 2),
          g_dayPL >= 0 ? C_GREEN : C_RED);
   HudSet("T4V", IntegerToString(g_dayEntries) +
          (InpMaxTradesPerDay > 0 ? " / " + IntegerToString(InpMaxTradesPerDay) : ""), C_TEXT);
   color lc = (g_lastSignal == "BUY") ? C_GREEN : (g_lastSignal == "SELL" ? C_RED : C_DIM);
   HudSet("T5V", g_lastSignal, lc);
   HudSet("T6V", "1 : " + DoubleToString(InpRiskReward, 1), C_TEXT);

   // --- AI console (typed reason, wrapped over two lines, blinking cursor)
   string cur  = blink ? "_" : " ";
   string r1   = StringSubstr(g_reason, 0, 40);
   string r2   = (StringLen(g_reason) > 40) ? StringSubstr(g_reason, 40, 40) : "";
   string line2;
   if(r2 != "")
      line2 = "  " + r2 + cur;
   else
      line2 = StringFormat("> score %d/%d | zones FVG %d OB %d%s",
                           a.score, InpMinConfluenceScore,
                           ArraySize(g_fvgBullZ) + ArraySize(g_fvgBearZ),
                           ArraySize(g_obBullZ) + ArraySize(g_obBearZ), cur);
   HudSet("CL1", "> " + r1 + (r2 == "" ? "" : ""), C_GREEN);
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
void DrawZoneSet(const Zone &arr[], string tag, color clr, ENUM_LINE_STYLE style)
{
   datetime t2 = TimeCurrent() + (datetime)(PeriodSeconds(PERIOD_CURRENT) * 12);
   int n = MathMin(ArraySize(arr), 40);
   for(int i = 0; i < n; i++)
   {
      string name = "TRS_Z_" + tag + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, arr[i].t, arr[i].hi, t2, arr[i].lo))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_FILL, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}

void DrawZones()
{
   if(!HudActive() || !InpDrawZones) return;

   ObjectsDeleteAll(0, "TRS_Z_");
   DrawZoneSet(g_fvgBullZ, "FB", C'0,200,200',  STYLE_DOT);
   DrawZoneSet(g_fvgBearZ, "FS", C'210,60,140', STYLE_DOT);
   DrawZoneSet(g_obBullZ,  "OB", C'0,230,120',  STYLE_SOLID);
   DrawZoneSet(g_obBearZ,  "OS", C'255,90,60',  STYLE_SOLID);
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

void DrawTradeLines()
{
   bool found = false;
   double entry = 0, sl = 0, tp = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      entry = PositionGetDouble(POSITION_PRICE_OPEN);
      sl    = PositionGetDouble(POSITION_SL);
      tp    = PositionGetDouble(POSITION_TP);
      found = true;
      break;
   }

   if(!found)
   {
      ObjectsDeleteAll(0, "TRS_L_");
      return;
   }

   SetHLine("TRS_L_ENTRY", entry, C_CYAN, "ENTRY");
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

//====================== CACHE REFRESH (NEW-BAR DRIVEN) ==============//
// Each refresh returns true only when its data is complete. On failure
// the "last bar" stamp is NOT updated, so the next tick retries.
bool RefreshHtfCache()
{
   datetime h1 = iTime(_Symbol, PERIOD_H1, 0);
   datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
   if(h1 == 0 || h4 == 0) return g_htfReady;

   if(g_htfReady && h1 == g_lastH1 && h4 == g_lastH4) return true;

   g_htfReady = false;
   if(!DetectSwingTrend(g_cache)) return false;
   if(!UpdatePDRange()) return false;

   g_lastH1   = h1;
   g_lastH4   = h4;
   g_htfReady = true;
   return true;
}

bool RefreshM15Cache()
{
   datetime t = iTime(_Symbol, PERIOD_M15, 0);
   if(t == 0) return g_m15Ready;

   if(g_m15Ready && t == g_lastM15) return true;

   g_m15Ready = false;
   if(!DetectLiquidity(g_cache))       return false;
   if(!DetectStructure(g_cache))       return false;
   if(!DetectM15Confirmation(g_cache)) return false;
   if(!ScanFVG())                      return false;
   if(!ScanOB())                       return false;

   g_lastM15  = t;
   g_m15Ready = true;
   DrawZones();
   return true;
}

// M5 sniper reads the last CLOSED M5 bar, so once per new bar is enough.
bool RefreshM5Cache()
{
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == 0) return g_m5Ready;

   if(g_m5Ready && t == g_lastM5) return true;

   g_m5Ready = false;
   if(!DetectM5Sniper(g_cache)) return false;

   g_lastM5  = t;
   g_m5Ready = true;
   return true;
}

bool PotentialZone()
{
   if(g_cache.bullishTrend &&
      (g_cache.fvgBull || g_cache.obBull || g_cache.liquidityBull))
      return true;

   if(g_cache.bearishTrend &&
      (g_cache.fvgBear || g_cache.obBear || g_cache.liquidityBear))
      return true;

   return false;
}

//=========================== TICK ENGINE ============================//
void FastTickEngine()
{
   bool htf = RefreshHtfCache();
   bool m15 = RefreshM15Cache();
   bool m5  = RefreshM5Cache();

   if(!(htf && m15 && m5))
   {
      g_status = "WAITING";
      g_reason = "Waiting for chart history";
      return;
   }

   // Cheap gates first.
   if(CountMyPositions() >= InpMaxPositions)
   {
      g_status = "SCANNING";
      g_reason = "Existing position - new entry blocked";
      return;
   }

   if(iTime(_Symbol, PERIOD_M5, 0) == g_lastAttemptBar)
   {
      g_status = "SCANNING";
      g_reason = "Entry already attempted on this M5 bar";
      return;
   }

   if(InpCooldownMinutes > 0 && g_lastTradeTime > 0 &&
      TimeCurrent() - g_lastTradeTime < (datetime)(InpCooldownMinutes * 60))
   {
      g_status = "WAITING";
      g_reason = "Cooldown after last entry";
      return;
   }

   if(!SpreadOK())
   {
      g_status = "WAITING";
      g_reason = "Spread too high";
      return;
   }

   if(!SessionOK())
   {
      g_status = "WAITING";
      g_reason = "Outside trading session";
      return;
   }

   // Live, price-dependent flags (FVG / OB / premium-discount).
   if(!UpdateLiveFlags(g_cache))
      return;
   CalculateScore(g_cache);

   if(!PotentialZone())
   {
      g_status = "SCANNING";
      g_reason = "No active SMC zone";
      return;
   }

   bool buy  = BuySignal(g_cache);
   bool sell = SellSignal(g_cache);

   if(!buy && !sell)
   {
      g_status = "ANALYSING";
      g_reason = "Potential zone - sniper confirmation pending";
      return;
   }

   if(buy && sell)
   {
      g_status = "SCANNING";
      g_reason = "Conflicting directional signals";
      return;
   }

   if(g_cache.score < InpMinConfluenceScore)
   {
      g_status = "REJECTED";
      g_reason = "Confluence score below minimum";
      return;
   }

   g_status = "SIGNAL CONFIRMED";
   g_reason = "Clean sniper entry confirmed";
   ExecuteSignal(g_cache, buy);
}

//========================== MT5 EVENTS ==============================//
int OnInit()
{
   if(InpSwingLookback < 1 || InpSwingLookback > 9 ||
      InpLiquidityLookback < 5 || InpFVGLookback < 5 || InpOBLookback < 5 ||
      InpMinConfluenceScore < 1 || InpMinConfluenceScore > 8 ||
      InpRiskReward <= 0 || InpMaxPositions < 1 ||
      InpRiskPercent < 0 || InpMaxDailyLossPercent < 0)
   {
      Print("Treasure v2.3: invalid input parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   ZeroMemory(g_cache);
   ArrayResize(g_fvgBullZ, 0);
   ArrayResize(g_fvgBearZ, 0);
   ArrayResize(g_obBullZ, 0);
   ArrayResize(g_obBearZ, 0);
   g_pdMid = 0.0;

   g_htfReady = false;
   g_m15Ready = false;
   g_m5Ready  = false;
   g_lastH1 = g_lastH4 = g_lastM15 = g_lastM5 = 0;
   g_lastAttemptBar = 0;
   g_lastTradeTime  = 0;
   g_tick = 0;

   g_status = "RUNNING";
   g_reason = "Scanning for confirmed SMC setup";

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
   ObjectsDeleteAll(0, HUD);       // HUD, zones (TRS_Z_) and lines (TRS_L_)
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
