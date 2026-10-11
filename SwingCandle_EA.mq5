//+------------------------------------------------------------------+
//|                                              SwingCandle_EA.mq5  |
//|  Multi-symbol swing trader: candlestick patterns + swing         |
//|  structure on M30 and H1. One EA instance scans all symbols.     |
//+------------------------------------------------------------------+
#property copyright "SwingCandle EA"
#property version   "1.00"
#property description "Candlestick patterns + swing structure, M30 & H1, all symbols"
#property strict

#include <Trade/Trade.mqh>

//--- inputs
input group "=== Universe ==="
input string InpSymbols         = "";     // Symbols (comma list). Empty = all Market Watch symbols
input int    InpMaxSymbols      = 40;     // Max symbols to scan
input bool   InpUseM30          = true;   // Scan 30M
input bool   InpUseH1           = true;   // Scan 1H

input group "=== Swing structure ==="
input int    InpSwingStrength   = 3;      // Bars each side to confirm a swing high/low
input int    InpSwingLookback   = 120;    // Bars to look back for swings
input bool   InpRequireH1Trend  = true;   // M30 signals must agree with H1 swing trend
input bool   InpUseEMAFilter    = true;   // Require EMA fast/slow alignment with trend
input int    InpEMAFast         = 50;
input int    InpEMASlow         = 200;
input double InpZoneATR         = 0.6;    // Pattern must form within this many ATR of swing level or fast EMA

input group "=== Candlestick patterns ==="
input bool   InpUseEngulfing    = true;   // Bullish / bearish engulfing
input bool   InpUsePinBar       = true;   // Hammer / shooting star
input bool   InpUseStars        = true;   // Morning / evening star
input double InpMinRangeATR     = 0.6;    // Signal candle range must be at least this many ATR

input group "=== Risk ==="
input double InpRiskPct         = 0.5;    // Risk per trade (% of balance)
input double InpRR              = 2.0;    // Take profit as multiple of stop distance
input double InpSLBufferATR     = 0.15;   // Stop buffer beyond pattern extreme (ATR)
input double InpMinSLATR        = 0.5;    // Minimum stop distance (ATR)
input double InpMaxSLATR        = 3.0;    // Skip trade if stop would be wider than this (ATR)
input double InpMaxSpreadATR    = 0.15;   // Skip if spread is wider than this (ATR)
input int    InpMaxPositions    = 8;      // Max open positions across all symbols
input double InpMaxDailyLossPct = 3.0;    // Stop new trades after this equity drop in a day (0 = off)
input int    InpFridayCutoffHour= 20;     // No new trades on Friday from this server hour (24 = off)

input group "=== Trade management ==="
input double InpBE_RR           = 1.0;    // Move SL to breakeven at this multiple of initial risk (0 = off)
input bool   InpUseTrail        = true;   // ATR trailing stop (starts after breakeven)
input double InpTrailATR        = 2.0;    // Trailing distance (H1 ATR multiple)

input group "=== Misc ==="
input long   InpMagic           = 770030;
input int    InpSlippage        = 30;
input string InpComment         = "SwingCandle";

//--- globals
CTrade          g_trade;
string          g_syms[];
datetime        g_last[];          // last processed closed-bar time, index = symbol*2 + tfIndex
ENUM_TIMEFRAMES g_tfs[2];
int             g_ntf = 0;
datetime        g_dayStart = 0;
double          g_dayStartEq = 0;
string          g_lastSignal = "none yet";

struct Swing { int idx; double price; };

//+------------------------------------------------------------------+
int OnInit()
  {
   g_ntf = 0;
   if(InpUseM30) g_tfs[g_ntf++] = PERIOD_M30;
   if(InpUseH1)  g_tfs[g_ntf++] = PERIOD_H1;
   if(g_ntf == 0)
     {
      Print("Enable at least one timeframe.");
      return INIT_PARAMETERS_INCORRECT;
     }

   BuildUniverse();
   int ns = ArraySize(g_syms);
   if(ns == 0)
     {
      Print("No symbols to scan.");
      return INIT_FAILED;
     }

   ArrayResize(g_last, ns * 2);
   for(int i = 0; i < ns * 2; i++) g_last[i] = 0;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);

   EventSetTimer(3);
   PrintFormat("SwingCandle EA started: %d symbols, %d timeframe(s)", ns, g_ntf);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer() { Run(); }

void OnTick()
  {
   // Timer drives live scanning; the tester has no reliable timer, so tick drives it there.
   if(MQLInfoInteger(MQL_TESTER)) Run();
  }

//+------------------------------------------------------------------+
void Run()
  {
   UpdateDayBaseline();
   ManagePositions();
   ScanAll();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
void AddSym(const string s)
  {
   int n = ArraySize(g_syms);
   ArrayResize(g_syms, n + 1);
   g_syms[n] = s;
  }

void BuildUniverse()
  {
   ArrayResize(g_syms, 0);
   if(StringLen(InpSymbols) > 0)
     {
      string parts[];
      int n = StringSplit(InpSymbols, ',', parts);
      for(int i = 0; i < n && ArraySize(g_syms) < InpMaxSymbols; i++)
        {
         string s = parts[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(s == "") continue;
         if(!SymbolSelect(s, true))
           {
            Print("Symbol not found: ", s);
            continue;
           }
         AddSym(s);
        }
     }
   else
     {
      int total = SymbolsTotal(true);
      for(int i = 0; i < total && ArraySize(g_syms) < InpMaxSymbols; i++)
        {
         string s = SymbolName(i, true);
         if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL) continue;
         AddSym(s);
        }
     }
  }

//+------------------------------------------------------------------+
//| Data helpers                                                      |
//+------------------------------------------------------------------+
bool LoadRates(const string sym, ENUM_TIMEFRAMES tf, int count, MqlRates &r[])
  {
   ArraySetAsSeries(r, true);
   int got = CopyRates(sym, tf, 0, count, r);
   return (got == count);
  }

double CalcATR(const MqlRates &r[], int period)
  {
   double sum = 0;
   for(int i = 1; i <= period; i++)
     {
      double tr = MathMax(r[i].high - r[i].low,
                  MathMax(MathAbs(r[i].high - r[i + 1].close),
                          MathAbs(r[i].low  - r[i + 1].close)));
      sum += tr;
     }
   return sum / period;
  }

// EMA value at 'shift' (series array: 0 = newest)
double CalcEMA(const MqlRates &r[], int period, int shift)
  {
   int count = ArraySize(r);
   double k = 2.0 / (period + 1.0);
   double ema = r[count - 1].close;
   for(int i = count - 2; i >= shift; i--)
      ema = r[i].close * k + ema * (1.0 - k);
   return ema;
  }

//+------------------------------------------------------------------+
//| Swing structure                                                   |
//+------------------------------------------------------------------+
// Finds the two most recent confirmed swing highs (high=true) or lows.
// s1 = most recent, s2 = the one before it.
bool FindSwings(const MqlRates &r[], bool high, Swing &s1, Swing &s2)
  {
   int k = InpSwingStrength;
   int maxI = MathMin(InpSwingLookback, ArraySize(r) - k - 1);
   int found = 0;
   for(int i = k + 1; i <= maxI; i++)
     {
      bool ok = true;
      for(int j = 1; j <= k; j++)
        {
         if(high)
           {
            if(r[i].high <= r[i - j].high || r[i].high <= r[i + j].high) { ok = false; break; }
           }
         else
           {
            if(r[i].low >= r[i - j].low || r[i].low >= r[i + j].low) { ok = false; break; }
           }
        }
      if(!ok) continue;

      double p = high ? r[i].high : r[i].low;
      if(found == 0)
        {
         s1.idx = i; s1.price = p; found = 1;
        }
      else
        {
         s2.idx = i; s2.price = p;
         return true;
        }
     }
   return false;
  }

// +1 uptrend (HH + HL), -1 downtrend (LH + LL), 0 unclear
int StructureTrend(const MqlRates &r[], Swing &swH, Swing &swL)
  {
   Swing h2, l2;
   if(!FindSwings(r, true,  swH, h2)) return 0;
   if(!FindSwings(r, false, swL, l2)) return 0;
   if(swH.price > h2.price && swL.price > l2.price) return 1;
   if(swH.price < h2.price && swL.price < l2.price) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Candlestick patterns on the last closed bars                      |
//+------------------------------------------------------------------+
// Returns +1 bullish, -1 bearish, 0 none. 'bars' = candles used by the pattern.
int DetectPattern(const MqlRates &r[], double atr, string &name, int &bars)
  {
   double o1 = r[1].open, h1 = r[1].high, l1 = r[1].low, c1 = r[1].close;
   double o2 = r[2].open, c2 = r[2].close;
   double o3 = r[3].open, h3 = r[3].high, l3 = r[3].low, c3 = r[3].close;

   double rng1 = h1 - l1;
   if(rng1 < InpMinRangeATR * atr) return 0;

   double body1 = MathAbs(c1 - o1);
   double body2 = MathAbs(c2 - o2);
   double body3 = MathAbs(c3 - o3);
   double rng3  = h3 - l3;
   double up1   = h1 - MathMax(o1, c1);
   double lo1   = MathMin(o1, c1) - l1;

   bool bull1 = c1 > o1, bear1 = c1 < o1;
   bool bull2 = c2 > o2, bear2 = c2 < o2;
   bool bull3 = c3 > o3, bear3 = c3 < o3;

   if(InpUseEngulfing)
     {
      if(bull1 && bear2 && o1 <= c2 && c1 >= o2 && body1 > body2)
        { name = "Bullish Engulfing"; bars = 2; return 1; }
      if(bear1 && bull2 && o1 >= c2 && c1 <= o2 && body1 > body2)
        { name = "Bearish Engulfing"; bars = 2; return -1; }
     }

   if(InpUsePinBar)
     {
      if(lo1 >= 2.0 * body1 && lo1 >= 0.6 * rng1 && up1 <= 0.25 * rng1)
        { name = "Hammer"; bars = 1; return 1; }
      if(up1 >= 2.0 * body1 && up1 >= 0.6 * rng1 && lo1 <= 0.25 * rng1)
        { name = "Shooting Star"; bars = 1; return -1; }
     }

   if(InpUseStars)
     {
      if(bear3 && body3 >= 0.5 * rng3 && body2 <= 0.5 * body3 && bull1 && c1 > (o3 + c3) / 2.0)
        { name = "Morning Star"; bars = 3; return 1; }
      if(bull3 && body3 >= 0.5 * rng3 && body2 <= 0.5 * body3 && bear1 && c1 < (o3 + c3) / 2.0)
        { name = "Evening Star"; bars = 3; return -1; }
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| Scanning                                                          |
//+------------------------------------------------------------------+
void ScanAll()
  {
   int ns = ArraySize(g_syms);
   for(int s = 0; s < ns; s++)
     {
      for(int k = 0; k < g_ntf; k++)
        {
         string sym = g_syms[s];
         ENUM_TIMEFRAMES tf = g_tfs[k];

         datetime t1 = iTime(sym, tf, 1);
         datetime t0 = iTime(sym, tf, 0);
         if(t1 == 0 || t0 == 0) continue;           // history not loaded yet, retry next pass

         int id = s * 2 + k;
         if(g_last[id] == t1) continue;             // this closed bar already processed

         // market closed / stale feed: mark processed and move on
         if(TimeCurrent() - t0 > PeriodSeconds(tf) * 2)
           {
            g_last[id] = t1;
            continue;
           }

         if(Evaluate(sym, tf)) g_last[id] = t1;
        }
     }
  }

// Returns false only if data was not ready (so the bar is retried).
bool Evaluate(const string sym, ENUM_TIMEFRAMES tf)
  {
   if(CountPositions(sym) > 0) return true;
   if(CountPositions() >= InpMaxPositions) return true;
   if(!TradingAllowedNow()) return true;

   MqlRates r[];
   if(!LoadRates(sym, tf, 400, r)) return false;

   double atr = CalcATR(r, 14);
   if(atr <= 0) return true;

   Swing swH, swL;
   int trend = StructureTrend(r, swH, swL);
   if(trend == 0) return true;

   // M30 setups must agree with the H1 swing trend
   if(InpRequireH1Trend && tf != PERIOD_H1)
     {
      MqlRates hr[];
      if(!LoadRates(sym, PERIOD_H1, 300, hr)) return false;
      Swing a, b;
      if(StructureTrend(hr, a, b) != trend) return true;
     }

   double emaF = CalcEMA(r, InpEMAFast, 1);
   double emaS = CalcEMA(r, InpEMASlow, 1);
   if(InpUseEMAFilter)
     {
      if(trend == 1  && !(emaF > emaS)) return true;
      if(trend == -1 && !(emaF < emaS)) return true;
     }

   string pname = "";
   int pbars = 1;
   int dir = DetectPattern(r, atr, pname, pbars);
   if(dir == 0 || dir != trend) return true;

   // pattern extreme and location check (pullback into swing level or fast EMA)
   double patLow = r[1].low, patHigh = r[1].high;
   for(int i = 2; i <= pbars; i++)
     {
      patLow  = MathMin(patLow,  r[i].low);
      patHigh = MathMax(patHigh, r[i].high);
     }
   double zone = InpZoneATR * atr;

   if(dir == 1)
     {
      bool nearSwing = MathAbs(patLow - swL.price) <= zone;
      bool nearEMA   = MathAbs(patLow - emaF) <= zone;
      if(!nearSwing && !nearEMA) return true;
     }
   else
     {
      bool nearSwing = MathAbs(patHigh - swH.price) <= zone;
      bool nearEMA   = MathAbs(patHigh - emaF) <= zone;
      if(!nearSwing && !nearEMA) return true;
     }

   // prices
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);

   if((ask - bid) > InpMaxSpreadATR * atr) return true;

   double entry = (dir == 1) ? ask : bid;
   double sl = (dir == 1) ? patLow - InpSLBufferATR * atr
                          : patHigh + InpSLBufferATR * atr;
   double slDist = MathAbs(entry - sl);

   if(slDist < InpMinSLATR * atr)
     {
      slDist = InpMinSLATR * atr;
      sl = (dir == 1) ? entry - slDist : entry + slDist;
     }
   if(slDist > InpMaxSLATR * atr) return true;      // structure too far away: skip

   double minDist = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(slDist <= minDist) return true;

   double tp = (dir == 1) ? entry + InpRR * slDist : entry - InpRR * slDist;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lots = CalcLots(sym, slDist);
   if(lots <= 0)
     {
      PrintFormat("%s: lot size below minimum for %.2f%% risk, skipped", sym, InpRiskPct);
      return true;
     }

   // margin check
   double margin = 0;
   ENUM_ORDER_TYPE ot = (dir == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(OrderCalcMargin(ot, sym, lots, entry, margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9) return true;

   g_trade.SetTypeFillingBySymbol(sym);
   bool ok = (dir == 1) ? g_trade.Buy(lots, sym, 0.0, sl, tp, InpComment)
                        : g_trade.Sell(lots, sym, 0.0, sl, tp, InpComment);

   g_lastSignal = StringFormat("%s %s %s %s @ %s", (dir == 1 ? "BUY" : "SELL"), sym,
                               EnumToString(tf), pname, TimeToString(TimeCurrent(), TIME_MINUTES));
   PrintFormat("%s lots=%.2f sl=%s tp=%s ok=%s ret=%u", g_lastSignal, lots,
               DoubleToString(sl, digits), DoubleToString(tp, digits),
               (ok ? "yes" : "no"), g_trade.ResultRetcode());
   return true;
  }

//+------------------------------------------------------------------+
//| Risk / sizing                                                     |
//+------------------------------------------------------------------+
double CalcLots(const string sym, double slDist)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || slDist <= 0) return 0;

   double lossPerLot = slDist / ts * tv;
   if(lossPerLot <= 0) return 0;

   double lots = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;

   lots = MathFloor(lots / step) * step;
   if(lots < mn) return 0;
   lots = MathMin(lots, mx);

   int vd = (int)MathMax(0.0, MathRound(-MathLog10(step)));
   return NormalizeDouble(lots, vd);
  }

int CountPositions(const string sym = "")
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(sym != "" && PositionGetString(POSITION_SYMBOL) != sym) continue;
      c++;
     }
   return c;
  }

void UpdateDayBaseline()
  {
   datetime now = TimeCurrent();
   datetime d = now - (now % 86400);
   if(d != g_dayStart)
     {
      g_dayStart = d;
      g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
     }
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLossPct <= 0 || g_dayStartEq <= 0) return false;
   return AccountInfoDouble(ACCOUNT_EQUITY) < g_dayStartEq * (1.0 - InpMaxDailyLossPct / 100.0);
  }

bool TradingAllowedNow()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour) return false;
   if(DailyLossHit()) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Position management: breakeven, then ATR trail                    |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym   = PositionGetString(POSITION_SYMBOL);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(sym, SYMBOL_ASK);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double minDist = (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(bid <= 0 || ask <= 0 || sl <= 0) continue;

      double newSL = sl;

      // H1 ATR for trailing
      double atr = 0;
      if(InpUseTrail)
        {
         MqlRates hr[];
         if(LoadRates(sym, PERIOD_H1, 40, hr)) atr = CalcATR(hr, 14);
        }

      if(type == POSITION_TYPE_BUY)
        {
         if(InpBE_RR > 0 && sl < open && (bid - open) >= InpBE_RR * (open - sl))
            newSL = open + (ask - bid);
         if(InpUseTrail && atr > 0 && newSL >= open)
           {
            double cand = bid - InpTrailATR * atr;
            if(cand > newSL) newSL = cand;
           }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > sl + 5 * point && newSL <= bid - minDist)
            g_trade.PositionModify(tk, newSL, tp);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         if(InpBE_RR > 0 && sl > open && (open - ask) >= InpBE_RR * (sl - open))
            newSL = open - (ask - bid);
         if(InpUseTrail && atr > 0 && newSL <= open)
           {
            double cand = ask + InpTrailATR * atr;
            if(cand < newSL) newSL = cand;
           }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL < sl - 5 * point && newSL >= ask + minDist)
            g_trade.PositionModify(tk, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   string s = "SwingCandle EA  |  candlestick patterns + swing structure  |  M30 & H1\n";
   s += StringFormat("Symbols scanned: %d   Open positions: %d / %d   Risk/trade: %.2f%%\n",
                     ArraySize(g_syms), CountPositions(), InpMaxPositions, InpRiskPct);
   s += "Daily loss limit: " + (DailyLossHit() ? "HIT - no new trades" : "OK") + "\n";
   s += "Last signal: " + g_lastSignal;
   Comment(s);
  }
//+------------------------------------------------------------------+
