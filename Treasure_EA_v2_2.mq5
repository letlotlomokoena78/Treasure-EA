//+------------------------------------------------------------------+
//|                    TREASURE EA v2.2                              |
//| Swing + SMC + Clean Sniper Confirmation                          |
//| Confirmed signal only | Target R:R 1:5                           |
//|                                                                  |
//| v2.2 changes (all review fixes):                                 |
//|  1. FVG / OB zones stored as price ranges, flags rebuilt (never  |
//|     sticky) and tested against live price every tick             |
//|  2. One entry attempt per M5 bar, cooldown, daily trade cap      |
//|  3. Position check filters by symbol + magic number              |
//|  4. Dashboard only on timer, reads cache, skipped in tester      |
//|  5. Risk % lot sizing, max SL cap, lot normalisation, margin     |
//|     check, daily loss limit                                      |
//|  6. Retry when history is not ready; H4 data is mandatory        |
//|  7. Real CHoCH definition, liquidity/structure ranges include    |
//|     bar 2, OB scan no longer reads the forming bar               |
//|  8. Filling mode set by symbol, optional local-time session      |
//|  9. Dead code removed                                            |
//+------------------------------------------------------------------+
#property version   "2.20"
#property description "Treasure EA v2.2 - Swing + SMC + Clean Sniper Entry"

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

input group "Display"
input bool   InpShowDashboard         = true;

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
   double lo;
   double hi;
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

//============================== HELPERS ==============================//
double PointValue()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double NormalizePrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
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

void AddZone(Zone &arr[], double lo, double hi)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].lo = lo;
   arr[n].hi = hi;
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
         AddZone(g_fvgBullZ, r[i + 2].high, r[i].low);

      if(r[i + 2].low > r[i].high)
         AddZone(g_fvgBearZ, r[i].high, r[i + 2].low);
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
         AddZone(g_obBullZ, r[i].low, r[i].high);

      // Bearish displacement after a bullish candle.
      if(r[i].close > r[i].open &&
         (r[i - 1].close < r[i].low || r[i - 2].close < r[i].low))
         AddZone(g_obBearZ, r[i].low, r[i].high);
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
      ok = trade.Buy(lots, _Symbol, 0.0, a.sl, a.tp, "TREASURE v2.2 BUY");
   else
      ok = trade.Sell(lots, _Symbol, 0.0, a.sl, a.tp, "TREASURE v2.2 SELL");

   if(ok)
   {
      g_lastSignal    = buy ? "BUY" : "SELL";
      g_lastTradeTime = TimeCurrent();
      g_status        = "EXECUTED";
      g_reason        = "Confirmed sniper signal";
      PrintFormat("Treasure v2.2 %s %.2f lots | SL %s | TP %s | score %d",
                  g_lastSignal, lots,
                  DoubleToString(a.sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  DoubleToString(a.tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  a.score);
      return true;
   }

   g_reason = "Order failed: " + trade.ResultRetcodeDescription();
   return false;
}

//=========================== DASHBOARD ==============================//
string BoolMark(bool v)
{
   return v ? "YES" : "NO";
}

// Reads the cache only - no analysis is recomputed here.
void Dashboard()
{
   if(!InpShowDashboard) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   Analysis a = g_cache;

   string trend = "NEUTRAL";
   if(a.bullishTrend) trend = "BULLISH";
   if(a.bearishTrend) trend = "BEARISH";

   string text;
   text  = "TREASURE EA v2.2\n";
   text += "============================\n";
   text += "STATUS: " + g_status + "\n";
   text += "SYMBOL: " + _Symbol + "\n";
   text += "TIME: " + TimeToString(TimeCurrent(), TIME_SECONDS) + "\n";
   text += "DATA READY H/M15/M5: " + BoolMark(g_htfReady) + "/" +
           BoolMark(g_m15Ready) + "/" + BoolMark(g_m5Ready) + "\n";
   text += "----------------------------\n";
   text += "H4/H1 TREND: " + trend + "\n";
   text += "LIQUIDITY BULL/BEAR: " + BoolMark(a.liquidityBull) + "/" + BoolMark(a.liquidityBear) + "\n";
   text += "BOS BULL/BEAR: " + BoolMark(a.bosBull) + "/" + BoolMark(a.bosBear) + "\n";
   text += "CHoCH BULL/BEAR: " + BoolMark(a.chochBull) + "/" + BoolMark(a.chochBear) + "\n";
   text += "FVG BULL/BEAR: " + BoolMark(a.fvgBull) + "/" + BoolMark(a.fvgBear) + "\n";
   text += "OB BULL/BEAR: " + BoolMark(a.obBull) + "/" + BoolMark(a.obBear) + "\n";
   text += "PREM/DISC BULL/BEAR: " + BoolMark(a.pdBull) + "/" + BoolMark(a.pdBear) + "\n";
   text += "M15 CONFIRM B/S: " + BoolMark(a.m15Bull) + "/" + BoolMark(a.m15Bear) + "\n";
   text += "M5 SNIPER B/S: " + BoolMark(a.m5Bull) + "/" + BoolMark(a.m5Bear) + "\n";
   text += "CONFLUENCE: " + IntegerToString(a.score) + "/8\n";
   text += "TARGET R:R: 1:" + DoubleToString(InpRiskReward, 1) + "\n";
   text += "SIGNAL: " + g_lastSignal + "\n";
   text += "REASON: " + g_reason + "\n";
   text += "============================";

   Comment(text);
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
      Print("Treasure v2.2: invalid input parameters");
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

   g_status = "RUNNING";
   g_reason = "Scanning for confirmed SMC setup";

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   Dashboard();
}

void OnTick()
{
   FastTickEngine();
}
//+------------------------------------------------------------------+
