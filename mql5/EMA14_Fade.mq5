//+------------------------------------------------------------------+
//|                                                  EMA14_Fade.mq5  |
//|              EMA14 Mean-Reversion Fade — Long & Short — XAUUSD M5|
//|                                                                  |
//|  CONTINUOUS TIER LOGIC (Cách C):                                 |
//|    longExt  = max over lookback of (high - ema) / dev            |
//|    shortExt = max over lookback of (ema - low)  / dev            |
//|    Setup gate: longExt >= InpMinEntryStd (float, e.g. 1.5)       |
//|    Confirm: low <= ema - armedExt*dev (exact σ, continuous)      |
//|                                                                  |
//|  GRID ENTRY (DCA fade deeper):                                   |
//|    Level 0 = main entry (market, fired at confirm touch)         |
//|    Level i = entry ± i*gridSpacing*dev (adverse direction)       |
//|    Risk = InpRiskPercent / gridLevels per level                  |
//|    SL = same for all levels (auto-bumped if collides with levels)|
//|    Fill: L0=market, L1+=pending limit; skip beyond SL            |
//|    Exit: TP hit → close ALL grid positions                       |
//|                                                                  |
//|  FILTERS:                                                        |
//|    - Vol Z-Score filter: atrShort < mean + N*stdev (blocks shocks)|
//|    - Full-bar filter: clean side before cross                    |
//|    - Min entry σ gate                                            |
//|    - Direction toggles (long/short)                              |
//|                                                                  |
//|  EXIT modes (per TP_Mode):                                       |
//|    TP_USD  : total floating PnL >= InpTP_USD                     |
//|    TP_BAND : price touches EMA ± N*σ (live band)                 |
//+------------------------------------------------------------------+
#property copyright "TradingView Agent Team"
#property version   "1.94"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==================================================================
//                              ENUMS
//==================================================================
enum ENUM_SL_BAND
{
   SL_NONE = 0, // No SL
   SL_2 = 2,    // 2σ
   SL_3 = 3,    // 3σ
   SL_4 = 4,    // 4σ
   SL_5 = 5,    // 5σ
   SL_6 = 6,    // 6σ
};

enum ENUM_SIZING_MODE
{
   SIZING_RISK       = 0,  // Risk-based: total InpRiskPercent split across armed levels
   SIZING_MARTINGALE = 1,  // Fixed start volume × multiplier^level_index
};

enum ENUM_ACC_SIZE
{
   ACC_EQUITY        = 0,  // Equity
   ACC_BALANCE       = 1,  // Balance
   ACC_BALANCE_CREDIT= 2,  // Balance + Credit
};


//==================================================================
//                              INPUTS
//==================================================================
input group "─── Strategy Logic ───"
input int    InpEmaLength       = 14;       // EMA Length
input int    InpDevLength       = 100;      // StdDev Length (close - EMA)
input int    InpMaxBarsToFire   = 2;        // Max bars: cross -> band touch
input int    InpBandLookback    = 4;        // Setup lookback (N bars)

input group "─── Vol Z-Score Filter ───"
input bool   InpUseVolZFilter   = true;    // Enable volatility z-score filter (ATR short vs baseline)
input int    InpAtrShortLen     = 3;       // Short ATR length (2-20). 3-5 = balanced
input int    InpAtrBaselineLen  = 100;     // Baseline length (mean+stdev of ATR)
input double InpVolZThreshold   = 2.0;     // Max Z-score threshold (block when atrShort >= mean + N*stdev)
input bool   InpLogVolZReject   = true;    // Log when Vol-Z filter rejects an entry

input group "─── Full-Bar Filter ───"
input bool   InpUseFullBarFilter = true;   // Enable full-bar filter before cross
input double InpFullBarOffset    = 0.3;    // Full-bar offset (σ): BUY needs low>EMA+Nσ, SELL needs high<EMA-Nσ

input group "─── Direction Toggles ───"
input bool   InpEnableLong    = true;      // Enable LONG entries
input bool   InpEnableShort   = true;      // Enable SHORT entries
input double InpMinEntryStd   = 1.0;       // Start filter σ (min setup extension, float)

input group "─── Position Sizing ───"
input ENUM_SIZING_MODE InpSizingMode   = SIZING_MARTINGALE; // Sizing mode
input double           InpRiskPercent  = 2.0;        // [RISK] Total risk % equity, split across levels
input double           InpStartVolume  = 0.01;       // [MARTINGALE] Start volume (lot for level 0)
input double           InpGridMult     = 1.5;        // [MARTINGALE] Multiplier per level (lot[i] = start * mult^i)
input ENUM_SL_BAND     InpSL_StdLevel  = SL_4;       // SL band level (2σ..6σ)
input double           InpMaxLotSize   = 1.0;        // Hard cap on lot size (per level)
input ENUM_ACC_SIZE    InpAccSizeMode  = ACC_EQUITY;  // Account size base (Equity/Balance/Balance+Credit)
input double           InpCommission   = 0.0;         // Commission per lot (one-way, account currency)

input group "─── Grid Entry ───"
input bool   InpUseGridEntry    = true;    // Enable grid entry (DCA adverse)
input int    InpGridLevels      = 5;       // Grid levels (incl. main entry, 2..10)
input double InpGridSpacingStd  = 0.5;     // Grid spacing (σ between levels)

input group "─── Take Profit (both can be enabled, first hit wins) ───"
input bool   InpUseTP_USD    = true;      // Enable TP by floating PnL (USD)
input double InpTP_USD       = 10.0;      // [TP_USD] Close when total floating PnL >= this USD
input bool   InpUseTP_Band   = false;     // Enable TP by price touching EMA ± N*σ
input double InpTP_BandBuy   = 0.0;       // [TP_BAND] BUY target σ (e.g. 0=EMA, 0.3=EMA+0.3σ)
input double InpTP_BandSell  = 0.0;       // [TP_BAND] SELL target σ (e.g. 0=EMA, 0.3=EMA−0.3σ)

input group "─── Telegram ───"
input bool   InpTelegramEnable  = false;          // Enable Telegram notifications
input string InpTelegramToken   = "";             // Bot Token (from @BotFather)
input string InpTelegramChatID  = "";             // Chat ID (user or group)
input bool   InpTelegramTest    = false;          // Send test message on startup
input bool   InpTgNotifyArmed   = true;           // Notify when setup is armed (yellow dot)
input bool   InpTgNotifyEntry   = true;           // Notify on entry signal (BUY/SELL)
input bool   InpTgNotifyTP      = true;           // Notify on TP hit (close positions)
input bool   InpTgNotifySL      = true;           // Notify on SL hit (grid auto-reset)
input bool   InpTgNotifyGridFill = false;         // Notify on each grid level fill

input group "─── Display ───"
input bool   InpShowPanel     = true;       // Show info panel on chart
input int    InpPanelX        = 16;         // Panel X (pixels from left)
input int    InpPanelY        = 28;         // Panel Y (pixels from top)
input bool   InpDrawLevels    = true;       // Draw EMA & σ-band curves on chart
input int    InpDrawBars      = 300;        // Draw indicator curves for N bars back
input bool   InpDrawBand1     = false;      // Draw ±1σ curve
input bool   InpDrawBand2     = true;       // Draw ±2σ curve
input bool   InpDrawBand3     = false;      // Draw ±3σ curve
input bool   InpDrawBand4     = true;       // Draw ±4σ curve
input bool   InpDrawSLBand    = true;       // Draw SL band curve

input group "─── Misc ───"
input long   InpMagic           = 20260410; // Magic number
input string InpComment         = "EMA14_Fade";
input int    InpSlippagePoints  = 30;       // Max slippage (points)

//==================================================================
//                              GLOBALS
//==================================================================
CTrade        trade;         // sync — dùng cho entry (cần biết filled hay chưa)
CTrade        tradeAsync;    // async — dùng cho đóng/xóa hàng loạt (fire-and-forget)
CPositionInfo posInfo;

// ─── Async close dedup guard (tránh resend khi position chưa biến mất khỏi terminal) ───
datetime      g_lastCloseCall   = 0;     // timestamp của lần gọi CloseAllPositions gần nhất
int           g_closeCooldownSec = 2;    // skip re-entry vào close trong N giây

int           hEma                 = INVALID_HANDLE;
int           hAtrShort            = INVALID_HANDLE;
datetime      lastBarTime          = 0;
int           barsSinceArmedLong   = -1;    // -1 = not armed
int           barsSinceArmedShort  = -1;
double        armedExtLong         = 0.0;   // σ-extension locked at cross
double        armedExtShort        = 0.0;

// ─── Grid state ───
// Khi signal fire, tạo sẵn N level prices. Track fill state per-level.
// activeGrid=true khi có ít nhất 1 level đã mở position.
bool          gridActive           = false;
int           gridDirection        = 0;     // +1 = LONG, -1 = SHORT
double        gridLevelPrice[10];           // Prices for each level
bool          gridLevelFilled[10];          // true = đã mở market order cho level này
double        gridLotByLevel[10];           // Lot size per level (martingale / risk-based)
int           gridLevelsArmed      = 0;     // Số level hợp lệ (sau khi filter SL)
int           gridPeakPositions    = 0;     // Max positions seen while grid active
double        gridSL               = 0.0;   // SL chung cho toàn grid

// ─── Signal block: prevent re-entry on same signal ───
// +1 = block LONG arm until crossUp resets it
// -1 = block SHORT arm until crossDown resets it
//  0 = no block
int           signalBlockDir       = 0;

// ─── Cached values for GUI (updated on new bar) ───
double        g_ema = 0, g_dev = 0;
double        g_atrZ = 0;        // volatility z-score (atrShort vs baseline mean/stdev)
bool          g_volBlocked = false;

// ─── Tick-based entry state (updated on new bar, checked every tick) ───
double        g_confirmLong  = 0;   // confirm price for LONG (bid must drop to this)
double        g_confirmShort = 0;   // confirm price for SHORT (ask must rise to this)
bool          g_windowLong   = false;
bool          g_windowShort  = false;

//==================================================================
//                              INIT
//==================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);

   // Async instance cho close/delete hàng loạt — OrderSendAsync return ngay không chờ broker
   tradeAsync.SetExpertMagicNumber(InpMagic);
   tradeAsync.SetMarginMode();
   tradeAsync.SetTypeFillingBySymbol(_Symbol);
   tradeAsync.SetDeviationInPoints((ulong)InpSlippagePoints);
   tradeAsync.SetAsyncMode(true);

   hEma = iMA(_Symbol, _Period, InpEmaLength, 0, MODE_EMA, PRICE_CLOSE);
   if(hEma == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA handle");
      return(INIT_FAILED);
   }

   hAtrShort = iATR(_Symbol, _Period, InpAtrShortLen);
   if(hAtrShort == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create short ATR handle");
      return(INIT_FAILED);
   }

   string tp_str = "";
   if(InpUseTP_USD)  tp_str += StringFormat("USD$%.2f ", InpTP_USD);
   if(InpUseTP_Band) tp_str += StringFormat("BAND(B%.2f/S%.2f)σ ", InpTP_BandBuy, InpTP_BandSell);
   if(tp_str == "")  tp_str = "NONE";
   string grid_str = InpUseGridEntry
                     ? StringFormat("%d@%.2fσ", InpGridLevels, InpGridSpacingStd)
                     : "OFF";
   string sizing_str = (InpSizingMode == SIZING_MARTINGALE)
                       ? StringFormat("MART %.2f×%.2f", InpStartVolume, InpGridMult)
                       : StringFormat("RISK %.1f%%", InpRiskPercent);
   PrintFormat("EMA14_Fade v1.94 | %s %s | L=%s S=%s | MinExt=%.2fσ Sizing=%s SL=%dσ TP=%s| Grid=%s",
               _Symbol, EnumToString(_Period),
               InpEnableLong ? "ON" : "OFF",
               InpEnableShort ? "ON" : "OFF",
               InpMinEntryStd, sizing_str, (int)InpSL_StdLevel,
               tp_str, grid_str);

   // Reset grid state
   gridActive        = false;
   gridDirection     = 0;
   gridLevelsArmed   = 0;
   gridPeakPositions = 0;
   for(int i = 0; i < 10; i++)
   {
      gridLevelPrice[i]  = 0;
      gridLevelFilled[i] = false;
      gridLotByLevel[i]  = 0;
   }

   // Telegram test on startup
   if(InpTelegramTest && InpTelegramEnable)
      SendTelegram("TEST OK — EMA14_Fade v1.94 connected!");

   PanelCreate();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   GUICleanup();
   if(hEma != INVALID_HANDLE)      IndicatorRelease(hEma);
   if(hAtrShort != INVALID_HANDLE) IndicatorRelease(hAtrShort);
}

//==================================================================
//                              HELPERS
//==================================================================
bool IsNewBar()
{
   datetime t = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

double GetEMA(int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hEma, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

// Population stdev of (close - EMA) — matches Pine ta.stdev (biased=true)
double GetDeviation(int length, int shift)
{
   double closes[]; double emas[];
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(emas, true);

   if(CopyClose(_Symbol, _Period, shift, length, closes) <= 0) return 0;
   if(CopyBuffer(hEma, 0, shift, length, emas) <= 0)           return 0;

   double sum = 0;
   for(int i = 0; i < length; i++) sum += (closes[i] - emas[i]);
   double mean = sum / length;

   double sumsq = 0;
   for(int i = 0; i < length; i++)
   {
      double r = (closes[i] - emas[i]) - mean;
      sumsq += r * r;
   }
   return MathSqrt(sumsq / length);
}

// ATR short value at `shift` bars back (0 = current, 1 = last closed).
double GetAtrShort(int shift)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hAtrShort, 0, shift, 1, buf) <= 0) return 0;
   return buf[0];
}

// Compute z-score of atrShort vs its (sma, stdev) over `baselineLen` bars ending at `shift`.
// Matches Pine: (atrShort - sma(atrShort,N)) / stdev(atrShort,N). Biased stdev (population).
// Returns 0 if baseline stdev == 0. Writes mean/stdev via output refs.
double GetAtrZScore(int baselineLen, int shift, double &meanOut, double &stdOut)
{
   meanOut = 0; stdOut = 0;
   if(baselineLen <= 1) return 0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hAtrShort, 0, shift, baselineLen, buf) <= 0) return 0;

   double sum = 0;
   for(int i = 0; i < baselineLen; i++) sum += buf[i];
   double mean = sum / baselineLen;

   double sumsq = 0;
   for(int i = 0; i < baselineLen; i++)
   {
      double r = buf[i] - mean;
      sumsq += r * r;
   }
   double std = MathSqrt(sumsq / baselineLen);

   meanOut = mean; stdOut = std;
   if(std <= 0) return 0;

   double atrNow = GetAtrShort(shift);
   return (atrNow - mean) / std;
}

// Live per-tick update of g_atrZ / g_volBlocked using shift=0 (current forming bar).
// ATR[0] cập nhật mỗi tick khi high/low của bar đang form thay đổi → z-score sẽ rướn
// lên ngay khi có spike, không cần chờ bar đóng. Noise cao hơn nhưng an toàn hơn
// ("thà không vào còn hơn vào nhầm spike").
void UpdateLiveVolZ()
{
   if(!InpUseVolZFilter)
   {
      g_atrZ = 0;
      g_volBlocked = false;
      return;
   }
   double mean = 0, std = 0;
   g_atrZ = GetAtrZScore(InpAtrBaselineLen, 0, mean, std);
   g_volBlocked = g_atrZ >= InpVolZThreshold;
}

//==================================================================
//                          TELEGRAM
//==================================================================
// URL-encode a string for Telegram sendMessage (handles common chars)
string UrlEncode(string text)
{
   string out = "";
   int len = StringLen(text);
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(text, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
         (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == '~')
         out += ShortToString(ch);
      else if(ch == ' ')
         out += "+";
      else if(ch == '\n')
         out += "%0A";
      else
         out += StringFormat("%%%02X", ch);
   }
   return out;
}

void SendTelegram(string message)
{
   if(!InpTelegramEnable) return;
   if(InpTelegramToken == "" || InpTelegramChatID == "") return;

   // Prefix with symbol & timeframe
   string prefix = StringFormat("[%s %s] ", _Symbol, EnumToString(_Period));
   string fullMsg = prefix + message;

   string url = "https://api.telegram.org/bot" + InpTelegramToken
              + "/sendMessage?chat_id=" + InpTelegramChatID
              + "&text=" + UrlEncode(fullMsg);

   char   post[];
   char   result[];
   string headers = "";
   int    timeout  = 5000;  // 5 seconds

   ResetLastError();
   int res = WebRequest("GET", url, headers, timeout, post, result, headers);

   if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         PrintFormat("TELEGRAM ERROR: Add https://api.telegram.org to allowed URLs (Tools > Options > Expert Advisors)");
      else
         PrintFormat("TELEGRAM ERROR: WebRequest failed, code=%d err=%d", res, err);
   }
   else if(res != 200)
   {
      string body = CharArrayToString(result);
      PrintFormat("TELEGRAM ERROR: HTTP %d | %s", res, body);
   }
}

//==================================================================
//                    GUI — PANEL & CHART LEVELS
//==================================================================
#define GP "EAF_"   // object name prefix

// ── Object helpers ───────────────────────────────────────
void _Rect(string id, int x, int y, int w, int h, color bg, color brd)
{
   string n = GP + id;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, brd);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN,       true);
}

void _Label(string id, int x, int y, string text, color clr, int sz = 9)
{
   string n = GP + id;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR,    ANCHOR_LEFT_UPPER);
      ObjectSetString (0, n, OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,    true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  sz);
   ObjectSetString (0, n, OBJPROP_TEXT,      text == "" ? " " : text);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     clr);
}

void _Button(string id, int x, int y, int w, int h, string text,
             color txtClr, color bg, color brd, int sz = 8)
{
   string n = GP + id;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,    true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,        h);
   ObjectSetString (0, n, OBJPROP_TEXT,         text);
   ObjectSetString (0, n, OBJPROP_FONT,         "Consolas");
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,     sz);
   ObjectSetInteger(0, n, OBJPROP_COLOR,        txtClr);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, brd);
}

void _HLine(string id, double price, color clr, int w = 1, ENUM_LINE_STYLE sty = STYLE_SOLID)
{
   string n = GP + id;
   if(price <= 0) { ObjectDelete(0, n); return; }
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,    true);
      ObjectSetInteger(0, n, OBJPROP_BACK,      true);
   }
   ObjectSetDouble (0, n, OBJPROP_PRICE, price);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_STYLE, sty);
}

void _HLineDel(string id) { ObjectDelete(0, GP + id); }

// Trend-line segment for curve drawing (bar i+1 → bar i)
void _Seg(string prefix, int idx, datetime t1, double p1, datetime t2, double p2,
          color clr, int w, ENUM_LINE_STYLE sty)
{
   string n = GP + "c" + prefix + IntegerToString(idx);
   if(p1 <= 0 || p2 <= 0) { ObjectDelete(0, n); return; }
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, n, OBJPROP_RAY_LEFT,  false);
      ObjectSetInteger(0, n, OBJPROP_BACK,      true);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,    true);
   }
   ObjectSetInteger(0, n, OBJPROP_TIME,  0, t1);
   ObjectSetDouble (0, n, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, n, OBJPROP_TIME,  1, t2);
   ObjectSetDouble (0, n, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_STYLE, sty);
}

// ── Panel build (called once in OnInit) ──────────────────
void PanelCreate()
{
   if(!InpShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   int px = InpPanelX, py = InpPanelY, pw = 290;
   _Rect("bg",  px, py, pw, 300, C'20,22,30', C'55,58,75');
   _Rect("hdr", px, py, pw, 24,  C'35,38,55', C'55,58,75');
   _Label("title", px + 10, py + 5, "EMA14 Fade v1.94", C'210,215,230', 10);

   // Buttons (bottom of panel — repositioned in PanelUpdate)
   _Button("btnTG",    px + 8,   py + 270, 130, 22, "Test Telegram",
           C'200,200,220', C'40,60,90', C'70,90,130');
   _Button("btnClose", px + 148, py + 270, 130, 22, "Close All",
           C'220,200,200', C'90,30,30', C'140,50,50');
}

// ── Panel update (every tick) ────────────────────────────
void PanelUpdate()
{
   if(!InpShowPanel) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   int px = InpPanelX, tx = px + 10, py = InpPanelY + 30;
   int rh = 17, row = 0, d = _Digits;
   color cDim = C'130,130,150', cTxt = C'185,185,200', cSep = C'50,53,68';
   color cLong = C'0,210,115', cShort = C'230,80,120';

   // ─ EMA / Dev / Ratio ─
   _Label("ema",   tx, py + rh * row, StringFormat("EMA   %.*f", d, g_ema), clrOrange); row++;
   _Label("dev",   tx, py + rh * row, StringFormat("Dev   %.5f", g_dev), cTxt); row++;
   _Label("ratio", tx, py + rh * row,
      StringFormat("VolZ  %.2f%s", g_atrZ, g_volBlocked ? "  BLOCKED" : ""),
      g_volBlocked ? C'220,80,80' : cDim); row++;
   _Label("sep1",  tx, py + rh * row, "------------------------------", cSep); row++;

   // ─ Status ─
   if(gridActive || HasOpenPosition())
   {
      double pnl = GetPositionPnL();
      int pc = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) pc++;

      _Label("st0", tx, py + rh * row,
         StringFormat("%s  %d positions", gridDirection > 0 ? "LONG" : "SHORT", pc),
         gridDirection > 0 ? cLong : cShort); row++;
      _Label("st1", tx, py + rh * row,
         StringFormat("PnL  $%.2f", pnl), pnl >= 0 ? cLong : C'230,80,80'); row++;
      _Label("st2", tx, py + rh * row,
         StringFormat("SL   %.*f", d, gridSL), C'230,80,80'); row++;
   }
   else if(barsSinceArmedLong >= 0)
   {
      _Label("st0", tx, py + rh * row,
         StringFormat("ARMED LONG  %.2f sig", armedExtLong), cLong); row++;
      double cp = (armedExtLong > 0) ? g_ema - armedExtLong * g_dev : 0;
      _Label("st1", tx, py + rh * row,
         StringFormat("Confirm <= %.*f", d, cp), C'220,220,100'); row++;
      _Label("st2", tx, py + rh * row,
         StringFormat("Window  %d / %d bars", barsSinceArmedLong, InpMaxBarsToFire), cTxt); row++;
   }
   else if(barsSinceArmedShort >= 0)
   {
      _Label("st0", tx, py + rh * row,
         StringFormat("ARMED SHORT  %.2f sig", armedExtShort), cShort); row++;
      double cp = (armedExtShort > 0) ? g_ema + armedExtShort * g_dev : 0;
      _Label("st1", tx, py + rh * row,
         StringFormat("Confirm >= %.*f", d, cp), C'220,220,100'); row++;
      _Label("st2", tx, py + rh * row,
         StringFormat("Window  %d / %d bars", barsSinceArmedShort, InpMaxBarsToFire), cTxt); row++;
   }
   else
   {
      _Label("st0", tx, py + rh * row, "IDLE -- scanning", C'110,110,130'); row++;
      _Label("st1", tx, py + rh * row, " ", cDim); row++;
      _Label("st2", tx, py + rh * row, " ", cDim); row++;
   }

   _Label("sep2", tx, py + rh * row, "------------------------------", cSep); row++;

   // ─ Config summary ─
   string sz = (InpSizingMode == SIZING_MARTINGALE)
      ? StringFormat("Mart %.2fx%.1f", InpStartVolume, InpGridMult)
      : StringFormat("Risk %.1f%%", InpRiskPercent);
   _Label("cfg0", tx, py + rh * row,
      StringFormat("L=%s S=%s  %s", InpEnableLong ? "ON" : "--", InpEnableShort ? "ON" : "--", sz), cDim); row++;

   string grd = InpUseGridEntry
      ? StringFormat("Grid %d@%.1fs", InpGridLevels, InpGridSpacingStd) : "Grid OFF";
   _Label("cfg1", tx, py + rh * row,
      StringFormat("SL %ds  %s", (int)InpSL_StdLevel, grd), cDim); row++;

   string tp = "";
   if(InpUseTP_USD)  tp += StringFormat("$%.0f ", InpTP_USD);
   if(InpUseTP_Band) tp += StringFormat("B%.1f/S%.1fs", InpTP_BandBuy, InpTP_BandSell);
   if(tp == "") tp = "None";
   _Label("cfg2", tx, py + rh * row, "TP: " + tp, cDim); row++;

   _Label("tg", tx, py + rh * row,
      InpTelegramEnable ? "Telegram: ON" : "Telegram: OFF",
      InpTelegramEnable ? C'80,180,80' : C'100,100,120'); row++;

   // ─ Resize panel & reposition buttons ─
   int contentH = 28 + row * rh + 8;
   int btnY = InpPanelY + contentH + 4;
   int totalH = contentH + 32;
   ObjectSetInteger(0, GP + "bg", OBJPROP_YSIZE, totalH);

   ObjectSetInteger(0, GP + "btnTG",    OBJPROP_YDISTANCE, btnY);
   ObjectSetInteger(0, GP + "btnClose", OBJPROP_YDISTANCE, btnY);
}

// ── Chart curves (called on new bar) ─────────────────────
// Batch-compute EMA & dev arrays, then draw trend-line segments
// for the last InpDrawBars bars → proper curves like TradingView.
void LevelsUpdate()
{
   if(!InpDrawLevels) { LevelsCleanup(); return; }

   int maxBars = MathMin(InpDrawBars, Bars(_Symbol, _Period) - InpDevLength - 10);
   if(maxBars < 2) return;

   // ── Batch copy price data ──
   double closes[], emaArr[];
   datetime times[];
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(emaArr, true);
   ArraySetAsSeries(times, true);

   int need = maxBars + InpDevLength + 5;
   if(CopyClose(_Symbol, _Period, 0, need, closes) < need) return;
   if(CopyBuffer(hEma, 0, 0, need, emaArr) < need)        return;
   if(CopyTime(_Symbol, _Period, 0, maxBars, times) < maxBars) return;

   // ── Compute dev[] for each of the maxBars bars ──
   double devArr[];
   ArrayResize(devArr, maxBars);
   for(int bar = 0; bar < maxBars; bar++)
   {
      double sum = 0;
      for(int j = 0; j < InpDevLength; j++)
         sum += (closes[bar + j] - emaArr[bar + j]);
      double mean = sum / InpDevLength;
      double sumsq = 0;
      for(int j = 0; j < InpDevLength; j++)
      {
         double r = (closes[bar + j] - emaArr[bar + j]) - mean;
         sumsq += r * r;
      }
      devArr[bar] = MathSqrt(sumsq / InpDevLength);
   }

   // ── Band config ──
   bool   bShow[4]; double bMult[4]; color bUp[4]; color bDn[4];
   bShow[0] = InpDrawBand1; bMult[0] = 1; bUp[0] = C'0,180,80';  bDn[0] = C'200,60,60';
   bShow[1] = InpDrawBand2; bMult[1] = 2; bUp[1] = C'0,150,65';  bDn[1] = C'180,50,50';
   bShow[2] = InpDrawBand3; bMult[2] = 3; bUp[2] = C'0,120,50';  bDn[2] = C'160,40,40';
   bShow[3] = InpDrawBand4; bMult[3] = 4; bUp[3] = C'0,100,40';  bDn[3] = C'140,30,30';

   double slMult = (double)(int)InpSL_StdLevel;

   // ── Draw segments bar-by-bar ──
   for(int i = 0; i < maxBars - 1; i++)
   {
      datetime t1 = times[i + 1], t2 = times[i];
      double   e1 = emaArr[i + 1], e2 = emaArr[i];
      double   d1 = devArr[i + 1], d2 = devArr[i];

      // EMA curve (orange)
      _Seg("E", i, t1, e1, t2, e2, clrOrange, 2, STYLE_SOLID);

      // σ band curves
      for(int b = 0; b < 4; b++)
      {
         if(bShow[b])
         {
            string up = "U" + IntegerToString(b + 1);
            string dn = "L" + IntegerToString(b + 1);
            _Seg(up, i, t1, e1 + bMult[b] * d1, t2, e2 + bMult[b] * d2, bUp[b], 1, STYLE_DOT);
            _Seg(dn, i, t1, e1 - bMult[b] * d1, t2, e2 - bMult[b] * d2, bDn[b], 1, STYLE_DOT);
         }
      }

      // SL band curves (fuchsia)
      if(InpDrawSLBand)
      {
         _Seg("SU", i, t1, e1 + slMult * d1, t2, e2 + slMult * d2, clrFuchsia, 1, STYLE_DASHDOT);
         _Seg("SD", i, t1, e1 - slMult * d1, t2, e2 - slMult * d2, clrFuchsia, 1, STYLE_DASHDOT);
      }
   }

   // ── Confirm price (horizontal line when armed) ──
   if(barsSinceArmedLong >= 0 && armedExtLong > 0)
      _HLine("confirm", g_ema - armedExtLong * g_dev, C'100,220,220', 1, STYLE_DASHDOTDOT);
   else if(barsSinceArmedShort >= 0 && armedExtShort > 0)
      _HLine("confirm", g_ema + armedExtShort * g_dev, C'100,220,220', 1, STYLE_DASHDOTDOT);
   else
      _HLineDel("confirm");

   ChartRedraw(0);
}

void LevelsCleanup()
{
   _HLineDel("confirm");
   // Curve objects are cleaned up by GUICleanup (prefix scan)
}

void GUICleanup()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, GP) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

// ── Button event handler ─────────────────────────────────
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;

   // Test Telegram button
   if(sparam == GP + "btnTG")
   {
      ObjectSetInteger(0, GP + "btnTG", OBJPROP_STATE, false);  // unpress
      if(InpTelegramToken == "" || InpTelegramChatID == "")
      {
         PrintFormat("Telegram test: Token or ChatID is empty!");
         return;
      }
      // Force-send even if InpTelegramEnable is off (test purpose)
      string prefix = StringFormat("[%s %s] ", _Symbol, EnumToString(_Period));
      string msg = prefix + "TEST OK — EMA14_Fade v1.94 connected!";
      string url = "https://api.telegram.org/bot" + InpTelegramToken
                 + "/sendMessage?chat_id=" + InpTelegramChatID
                 + "&text=" + UrlEncode(msg);
      char post[], result[];
      string headers = "";
      int res = WebRequest("GET", url, headers, 5000, post, result, headers);
      if(res == 200)
         PrintFormat("Telegram test: SUCCESS");
      else if(res == -1 && GetLastError() == 4014)
         PrintFormat("Telegram test: FAILED — add https://api.telegram.org to allowed URLs");
      else
         PrintFormat("Telegram test: FAILED — HTTP %d", res);
   }

   // Close All button
   if(sparam == GP + "btnClose")
   {
      ObjectSetInteger(0, GP + "btnClose", OBJPROP_STATE, false);
      if(HasOpenPosition())
      {
         PrintFormat("MANUAL CLOSE ALL triggered from GUI");
         if(InpTgNotifyTP && InpTelegramEnable)
            SendTelegram("MANUAL CLOSE ALL (GUI button)");
         CloseAllPositions("MANUAL_GUI");
      }
      else
         PrintFormat("Close All: no open positions");
   }
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            return true;
      }
   }
   return false;
}

// Sum floating PnL across ALL positions belonging to this EA (grid-aware)
double GetPositionPnL()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            total += posInfo.Profit() + posInfo.Swap();
      }
   }
   return total;
}

// Count pending orders belonging to this EA
int CountPendingOrders()
{
   int cnt = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      cnt++;
   }
   return cnt;
}

// Delete all pending orders belonging to this EA (async — fire & forget)
void DeletePendingOrders()
{
   int fired = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;

      // Async: submit request và return ngay, không chờ broker confirm
      if(tradeAsync.OrderDelete(ticket))
         fired++;
      else
         PrintFormat("Delete REJECTED #%I64u: %s", ticket, tradeAsync.ResultRetcodeDescription());
   }
   if(fired > 0) PrintFormat("Async delete submitted: %d pending orders", fired);
}

void CloseAllPositions(string reason)
{
   // Dedup guard: async close có thể mất 50-200ms để biến mất khỏi terminal.
   // Trong khoảng đó OnTick có thể gọi lại CloseAllPositions → duplicate close requests.
   // Guard: skip re-entry trong cooldown window (broker sẽ vẫn hoàn tất request đã gửi).
   datetime now = TimeCurrent();
   if(g_lastCloseCall > 0 && (now - g_lastCloseCall) < g_closeCooldownSec)
   {
      PrintFormat("CloseAll skipped (cooldown): reason=%s, last=%ds ago",
                  reason, (int)(now - g_lastCloseCall));
      return;
   }
   g_lastCloseCall = now;

   // Delete pending orders FIRST (async), sau đó close positions (async) — broker
   // nhận các request gần như đồng thời → đóng ở giá gần như giống nhau
   DeletePendingOrders();

   int fired = 0;
   double totalPnL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         {
            ulong ticket = posInfo.Ticket();
            double pnl   = posInfo.Profit();
            totalPnL    += pnl;
            // Async close — fire ngay, broker xử lý song song các request
            if(tradeAsync.PositionClose(ticket))
               fired++;
            else
               PrintFormat("Close REJECTED #%I64u: %s", ticket, tradeAsync.ResultRetcodeDescription());
         }
      }
   }
   if(fired > 0)
      PrintFormat("Async close submitted: %d positions (%s) | snapshot PnL=%.2f",
                  fired, reason, totalPnL);

   // Block same-direction signal BEFORE resetting gridDirection
   signalBlockDir = gridDirection;  // +1 blocks LONG, -1 blocks SHORT

   // Reset grid state after closing
   gridActive        = false;
   gridDirection     = 0;
   gridLevelsArmed   = 0;
   gridPeakPositions = 0;
   for(int j = 0; j < 10; j++)
   {
      gridLevelPrice[j]  = 0;
      gridLevelFilled[j] = false;
      gridLotByLevel[j]  = 0;
   }
   // Clear armed state
   barsSinceArmedLong = -1;   armedExtLong  = 0;
   barsSinceArmedShort = -1;  armedExtShort = 0;
   g_confirmLong = 0;  g_windowLong  = false;
   g_confirmShort = 0; g_windowShort = false;
   PrintFormat("Signal block: %s blocked until opposite cross (%s)",
               signalBlockDir > 0 ? "LONG" : signalBlockDir < 0 ? "SHORT" : "NONE", reason);
}

// Position Sizer formula (matches EarnForex Position Sizer):
//   lots = RiskMoney / (SL_distance × UnitCost / TickSize + 2 × Commission)
//
// Where:
//   RiskMoney  = AccSize × Risk% / 100
//   UnitCost   = TICK_VALUE_LOSS (Forex/Futures) or TickSize × ContractSize (CFD/Stocks)
//   TickSize   = SYMBOL_TRADE_TICK_SIZE
//   Commission = per-lot one-way commission (counted ×2 for open+close)
//   SL_distance= |entry − SL| in price units
//
// slPriceDistance: SL distance in PRICE (not points!)
double CalculateLotSize(double slPriceDistance, double risk_percent)
{
   // ─── Account size ───
   double accSize = 0;
   switch(InpAccSizeMode)
   {
      case ACC_EQUITY:         accSize = AccountInfoDouble(ACCOUNT_EQUITY);  break;
      case ACC_BALANCE:        accSize = AccountInfoDouble(ACCOUNT_BALANCE); break;
      case ACC_BALANCE_CREDIT: accSize = AccountInfoDouble(ACCOUNT_BALANCE)
                                       + AccountInfoDouble(ACCOUNT_CREDIT);  break;
   }

   double riskMoney = accSize * (risk_percent / 100.0);

   // ─── Unit cost (tick value) ───
   ENUM_SYMBOL_CALC_MODE calcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double unitCost  = 0;

   if(calcMode == SYMBOL_CALC_MODE_FOREX || calcMode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE ||
      calcMode == SYMBOL_CALC_MODE_FUTURES || calcMode == SYMBOL_CALC_MODE_EXCH_FUTURES ||
      calcMode == SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS)
   {
      unitCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(unitCost <= 0) unitCost = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   }
   else  // CFD, Stocks, etc.
   {
      unitCost = tickSize * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   }

   if(tickSize <= 0 || unitCost <= 0 || slPriceDistance <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // ─── Position Sizer formula ───
   double commission = InpCommission;  // per lot, one-way
   double costPerLot = slPriceDistance * unitCost / tickSize + 2.0 * commission;

   if(costPerLot <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = riskMoney / costPerLot;

   // ─── Normalize to broker constraints ───
   double vol_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / vol_step) * vol_step;  // round DOWN (same as Position Sizer)
   lots = MathMax(vol_min, MathMin(lots, vol_max));
   lots = MathMin(lots, InpMaxLotSize);
   return NormalizeDouble(lots, 2);
}

//==================================================================
//                          GRID HELPERS
//==================================================================
// Setup grid state khi signal fire. Tính levels, filter theo SL, calc lot.
// direction: +1 = LONG, -1 = SHORT
// entryPrice: market price khi signal fire
// slPrice: SL chung cho toàn grid
// dev: stdev tại bar signal
// Normalize 1 lot value to broker's volume step / min / max / hard cap
double NormalizeLot(double lot)
{
   double vol_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vol_step <= 0) vol_step = 0.01;
   lot = MathFloor(lot / vol_step) * vol_step;
   lot = MathMax(vol_min, MathMin(lot, vol_max));
   lot = MathMin(lot, InpMaxLotSize);
   return NormalizeDouble(lot, 2);
}

void SetupGrid(int direction, double entryPrice, double slPrice, double dev)
{
   int nLevels = InpUseGridEntry ? InpGridLevels : 1;
   if(nLevels > 10) nLevels = 10;
   if(nLevels < 1)  nLevels = 1;

   gridActive      = true;
   gridDirection   = direction;
   gridSL          = slPrice;
   gridLevelsArmed = 0;

   // ─── Pass 1: build level prices, filter out levels beyond SL ───
   bool levelValid[10];
   for(int i = 0; i < 10; i++) levelValid[i] = false;

   for(int i = 0; i < nLevels; i++)
   {
      double offset = i * InpGridSpacingStd * dev;
      double price  = (direction > 0) ? (entryPrice - offset) : (entryPrice + offset);

      // Skip if level is beyond SL OR too close to SL (min 1 grid spacing distance)
      // If SL=0 (no SL), skip these checks — all levels are valid
      bool beyondSL = false, tooClose = false;
      double distToSL = 0, minDistToSL = 0;
      if(slPrice > 0)
      {
         minDistToSL = InpGridSpacingStd * dev;
         distToSL    = MathAbs(price - slPrice);
         beyondSL = (direction > 0) ? (price <= slPrice) : (price >= slPrice);
         tooClose = (distToSL < minDistToSL) && (i > 0);
      }
      if(beyondSL || tooClose)
      {
         PrintFormat("Grid L%d skipped: price %.5f %s SL %.5f (dist=%.5f min=%.5f)",
                     i, price, beyondSL ? "beyond" : "too close to", slPrice, distToSL, minDistToSL);
         gridLevelPrice[i]  = 0;
         gridLevelFilled[i] = true;  // mark as consumed
         gridLotByLevel[i]  = 0;
         levelValid[i]      = false;
         continue;
      }

      gridLevelPrice[i]  = price;
      gridLevelFilled[i] = false;
      levelValid[i]      = true;
      gridLevelsArmed++;
   }
   // Clear unused slots
   for(int j = nLevels; j < 10; j++)
   {
      gridLevelPrice[j]  = 0;
      gridLevelFilled[j] = true;
      gridLotByLevel[j]  = 0;
      levelValid[j]      = false;
   }

   // ─── Pass 2: sizing per level (by mode) ───
   if(InpSizingMode == SIZING_MARTINGALE)
   {
      // lot[i] = start * mult^i, normalized; skipped levels get 0
      for(int i = 0; i < nLevels; i++)
      {
         if(!levelValid[i]) { gridLotByLevel[i] = 0; continue; }
         double raw = InpStartVolume * MathPow(InpGridMult, i);
         gridLotByLevel[i] = NormalizeLot(raw);
      }
   }
   else  // SIZING_RISK
   {
      // Total risk split equally across armed levels; each level sized by SL distance from ITS price
      double risk_per_level = InpRiskPercent / MathMax(1, gridLevelsArmed);
      for(int i = 0; i < nLevels; i++)
      {
         if(!levelValid[i]) { gridLotByLevel[i] = 0; continue; }
         double sl_dist = MathAbs(gridLevelPrice[i] - slPrice);  // price distance
         gridLotByLevel[i] = CalculateLotSize(sl_dist, risk_per_level);
      }
   }

   // ─── Log ───
   string lot_str = "";
   for(int i = 0; i < nLevels; i++)
   {
      if(i > 0) lot_str += "/";
      lot_str += StringFormat("%.2f", gridLotByLevel[i]);
   }
   string mode_str = (InpSizingMode == SIZING_MARTINGALE)
                     ? StringFormat("MART start=%.2f ×%.2f", InpStartVolume, InpGridMult)
                     : StringFormat("RISK %.1f%%/%d", InpRiskPercent, gridLevelsArmed);
   PrintFormat("Grid setup: dir=%s levels=%d (armed=%d) spacing=%.2fσ SL=%.5f | %s | lots=[%s]",
               direction > 0 ? "LONG" : "SHORT",
               nLevels, gridLevelsArmed, InpGridSpacingStd, slPrice,
               mode_str, lot_str);
}

// Place all grid orders in one pass:
//   L0  = market SYNC (confirm fill trước khi đặt pendings)
//   L1+ = pending limit ASYNC (fire gần đồng thời sau khi L0 fill xong)
// Called ONCE after SetupGrid (not every tick).
void ProcessGridFills()
{
   if(!gridActive) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = 0; i < 10; i++)
   {
      if(gridLevelFilled[i]) continue;
      if(gridLevelPrice[i] <= 0) continue;

      double lot = gridLotByLevel[i];
      if(lot <= 0) { gridLevelFilled[i] = true; continue; }

      string cmt = StringFormat("%s_G%d", InpComment, i);
      bool ok = false;

      if(i == 0)
      {
         // Level 0: market SYNC — xác nhận fill trước khi đi tiếp
         ok = (gridDirection > 0)
              ? trade.Buy (lot, _Symbol, ask, gridSL, 0, cmt)
              : trade.Sell(lot, _Symbol, bid, gridSL, 0, cmt);

         if(ok)
            PrintFormat("Grid L0 MARKET %s %.2f lot @ %.5f",
                        gridDirection > 0 ? "BUY" : "SELL", lot,
                        gridDirection > 0 ? ask : bid);
         else
         {
            // L0 fail → không đặt pendings, thoát để tránh grid lơ lửng
            PrintFormat("Grid L0 FAILED (%.2f lot): %d (%s) → aborting grid",
                        lot, trade.ResultRetcode(), trade.ResultRetcodeDescription());
            return;
         }
      }
      else
      {
         // Levels 1+: pending limit ASYNC — fire gần đồng thời (~5ms total)
         if(gridDirection > 0)
            ok = tradeAsync.BuyLimit(lot, gridLevelPrice[i], _Symbol, gridSL, 0, ORDER_TIME_GTC, 0, cmt);
         else
            ok = tradeAsync.SellLimit(lot, gridLevelPrice[i], _Symbol, gridSL, 0, ORDER_TIME_GTC, 0, cmt);

         if(ok)
            PrintFormat("Grid L%d PENDING(async) %s_LIMIT %.2f lot @ %.5f",
                        i, gridDirection > 0 ? "BUY" : "SELL", lot, gridLevelPrice[i]);
      }

      if(ok)
      {
         gridLevelFilled[i] = true;
         if(InpTgNotifyGridFill)
            SendTelegram(StringFormat("Grid L%d %s\n%s %.2f lot @ %.5f",
                         i, i == 0 ? "MARKET" : "LIMIT",
                         gridDirection > 0 ? "BUY" : "SELL", lot,
                         i == 0 ? (gridDirection > 0 ? ask : bid) : gridLevelPrice[i]));
      }
      else
      {
         // L0 dùng trade (sync), L1+ dùng tradeAsync — đọc retcode từ instance tương ứng
         int    rc    = (i == 0) ? trade.ResultRetcode()           : tradeAsync.ResultRetcode();
         string rcStr = (i == 0) ? trade.ResultRetcodeDescription() : tradeAsync.ResultRetcodeDescription();
         PrintFormat("Grid L%d ORDER FAILED (%.2f lot): %d (%s)", i, lot, rc, rcStr);
      }
   }
}

//==================================================================
//                     EXECUTE ENTRY HELPERS
//==================================================================
void ExecuteLong(double entryExt)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = 0;  // 0 = no SL

   if(InpSL_StdLevel != SL_NONE)
   {
      double sl_mult  = (double)(int)InpSL_StdLevel;
      double grid_min = entryExt + (InpUseGridEntry ? (InpGridLevels - 1) * InpGridSpacingStd : 0);
      double min_valid = MathMax(entryExt, grid_min) + 1e-6;
      bool   bumped   = false;
      if(sl_mult <= min_valid)
      {
         sl_mult = MathCeil(min_valid);
         if(sl_mult <= min_valid) sl_mult = min_valid + 1.0;
         bumped = true;
      }
      sl = NormalizeDouble(g_ema - sl_mult * g_dev, _Digits);
      if(sl >= ask) { PrintFormat("BUY SKIP: SL %.5f >= ask %.5f", sl, ask); return; }

      PrintFormat("BUY SIGNAL (%.2fσ) | ask=%.5f SL=%.5f (%.1fσ%s) dev=%.5f",
                  entryExt, ask, sl, sl_mult, bumped ? " BUMPED" : "", g_dev);
   }
   else
      PrintFormat("BUY SIGNAL (%.2fσ) | ask=%.5f SL=NONE dev=%.5f", entryExt, ask, g_dev);

   if(InpTgNotifyEntry)
      SendTelegram(StringFormat("BUY SIGNAL (%.2fσ)\nentry=%.5f SL=%s\ndev=%.5f | grid=%d levels",
                   entryExt, ask, sl > 0 ? DoubleToString(sl, _Digits) : "NONE",
                   g_dev, InpUseGridEntry ? InpGridLevels : 1));

   SetupGrid(+1, ask, sl, g_dev);
   ProcessGridFills();
}

void ExecuteShort(double entryExt)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = 0;  // 0 = no SL

   if(InpSL_StdLevel != SL_NONE)
   {
      double sl_mult  = (double)(int)InpSL_StdLevel;
      double grid_min = entryExt + (InpUseGridEntry ? (InpGridLevels - 1) * InpGridSpacingStd : 0);
      double min_valid = MathMax(entryExt, grid_min) + 1e-6;
      bool   bumped   = false;
      if(sl_mult <= min_valid)
      {
         sl_mult = MathCeil(min_valid);
         if(sl_mult <= min_valid) sl_mult = min_valid + 1.0;
         bumped = true;
      }
      sl = NormalizeDouble(g_ema + sl_mult * g_dev, _Digits);
      if(sl <= bid) { PrintFormat("SELL SKIP: SL %.5f <= bid %.5f", sl, bid); return; }

      PrintFormat("SELL SIGNAL (%.2fσ) | bid=%.5f SL=%.5f (%.1fσ%s) dev=%.5f",
                  entryExt, bid, sl, sl_mult, bumped ? " BUMPED" : "", g_dev);
   }
   else
      PrintFormat("SELL SIGNAL (%.2fσ) | bid=%.5f SL=NONE dev=%.5f", entryExt, bid, g_dev);

   if(InpTgNotifyEntry)
      SendTelegram(StringFormat("SELL SIGNAL (%.2fσ)\nentry=%.5f SL=%s\ndev=%.5f | grid=%d levels",
                   entryExt, bid, sl > 0 ? DoubleToString(sl, _Digits) : "NONE",
                   g_dev, InpUseGridEntry ? InpGridLevels : 1));

   SetupGrid(-1, bid, sl, g_dev);
   ProcessGridFills();
}

//==================================================================
//                              MAIN
//==================================================================
void OnTick()
{
   //── 0a. Auto-reset grid if SL hit (detect position count drop) ──
   if(gridActive)
   {
      // Count current positions
      int curPos = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) curPos++;
      // Track peak
      if(curPos > gridPeakPositions) gridPeakPositions = curPos;
      // Detect SL: positions decreased → broker closed some → kill everything
      bool slDetected = (curPos == 0) || (gridPeakPositions > 0 && curPos < gridPeakPositions);
      if(slDetected)
      {
         // Close any remaining positions + delete all pending orders
         if(curPos > 0)
         {
            PrintFormat("Grid partial SL: %d/%d positions remain → closing all + deleting pending",
                        curPos, gridPeakPositions);
            CloseAllPositions("PARTIAL_SL");
            return;  // CloseAllPositions handles reset + signal block
         }
      }
   }
   if(gridActive && !HasOpenPosition())
   {
      PrintFormat("Grid auto-reset: all positions closed (likely SL)");
      DeletePendingOrders();
      if(InpTgNotifySL)
         SendTelegram("SL HIT — all positions closed (grid auto-reset)");
      // Block same-direction signal
      signalBlockDir = gridDirection;
      // Clear armed state
      barsSinceArmedLong = -1;  armedExtLong = 0;
      barsSinceArmedShort = -1; armedExtShort = 0;
      g_confirmLong = 0;  g_windowLong = false;
      g_confirmShort = 0; g_windowShort = false;
      PrintFormat("Signal block: %s blocked until opposite cross",
                  signalBlockDir > 0 ? "LONG" : "SHORT");
      gridActive      = false;
      gridDirection   = 0;
      gridLevelsArmed = 0;
      for(int k = 0; k < 10; k++)
      {
         gridLevelPrice[k]  = 0;
         gridLevelFilled[k] = false;
         gridLotByLevel[k]  = 0;
      }
   }

   //── 0b. Live Vol-Z update per tick (shift=0, bar đang form) ──
   //   Accept nhiễu cao hơn để filter phản ứng ngay với spike
   //   thay vì chờ bar đóng.
   UpdateLiveVolZ();

   //── 0c. GUI panel update (every tick for live PnL) ──
   PanelUpdate();

   //── 1. TP check (every tick, first hit wins) ──────────────
   if(HasOpenPosition())
   {
      double pnl = GetPositionPnL();  // total across ALL grid positions

      // If gridDirection lost (EA restart mid-grid), resync from first position
      if(gridDirection == 0)
      {
         for(int i = 0; i < PositionsTotal(); i++)
         {
            if(posInfo.SelectByIndex(i) &&
               posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            {
               gridDirection = (posInfo.PositionType() == POSITION_TYPE_BUY) ? +1 : -1;
               break;
            }
         }
      }

      // Check A: TP by USD (total floating PnL)
      if(InpUseTP_USD && pnl >= InpTP_USD)
      {
         PrintFormat("TP HIT (USD): total PnL=$%.2f >= target $%.2f", pnl, InpTP_USD);
         if(InpTgNotifyTP)
            SendTelegram(StringFormat("TP HIT (USD)\nPnL=$%.2f >= target $%.2f", pnl, InpTP_USD));
         CloseAllPositions("TP_USD");
         return;
      }

      // Check B: TP by price touching EMA ± N*σ (separate levels for BUY/SELL)
      if(InpUseTP_Band)
      {
         double ema0 = GetEMA(0);
         double dev0 = GetDeviation(InpDevLength, 0);
         if(ema0 > 0 && dev0 > 0)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            bool hit = false;
            double tpPrice = 0;
            double n = 0;

            if(gridDirection > 0)  // BUY: TP khi bid >= EMA + InpTP_BandBuy*σ
            {
               n = InpTP_BandBuy;
               tpPrice = ema0 + n * dev0;
               hit = (bid >= tpPrice);
            }
            else if(gridDirection < 0)  // SELL: TP khi ask <= EMA - InpTP_BandSell*σ
            {
               n = InpTP_BandSell;
               tpPrice = ema0 - n * dev0;
               hit = (ask <= tpPrice);
            }

            if(hit)
            {
               PrintFormat("TP HIT (BAND %.2fσ): pnl=$%.2f | target=%.5f bid=%.5f ask=%.5f",
                           n, pnl, tpPrice, bid, ask);
               if(InpTgNotifyTP)
                  SendTelegram(StringFormat("TP HIT (BAND %.2fσ)\nPnL=$%.2f | target=%.5f", n, pnl, tpPrice));
               CloseAllPositions("TP_BAND");
               return;
            }
         }
      }
   }

   //── 2. TICK-BASED ENTRY: giá chạm confirm → vào lệnh ngay ──
   if(!gridActive && !HasOpenPosition() && g_ema > 0)
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // LONG: bid chạm confirm price
      if(g_windowLong && InpEnableLong && g_confirmLong > 0 && bid <= g_confirmLong)
      {
         if(g_volBlocked)
         {
            if(InpLogVolZReject)
               PrintFormat("Vol-Z REJECT LONG @ %.*f | volZ=%.2f (thr=%.2f) | ext=%.2fσ → armed cancelled",
                           _Digits, bid, g_atrZ, InpVolZThreshold, armedExtLong);
            // Reject = hủy hẳn armed state (không chờ volZ giảm lại)
            barsSinceArmedLong = -1;  armedExtLong = 0;
            g_confirmLong = 0;  g_windowLong = false;
         }
         else
         {
            double ext = armedExtLong;
            // Reset armed state
            barsSinceArmedLong = -1;  armedExtLong = 0;
            g_confirmLong = 0;  g_windowLong = false;
            ExecuteLong(ext);
            return;
         }
      }

      // SHORT: ask chạm confirm price
      if(g_windowShort && InpEnableShort && g_confirmShort > 0 && ask >= g_confirmShort)
      {
         if(g_volBlocked)
         {
            if(InpLogVolZReject)
               PrintFormat("Vol-Z REJECT SHORT @ %.*f | volZ=%.2f (thr=%.2f) | ext=%.2fσ → armed cancelled",
                           _Digits, ask, g_atrZ, InpVolZThreshold, armedExtShort);
            barsSinceArmedShort = -1;  armedExtShort = 0;
            g_confirmShort = 0;  g_windowShort = false;
         }
         else
         {
            double ext = armedExtShort;
            barsSinceArmedShort = -1;  armedExtShort = 0;
            g_confirmShort = 0;  g_windowShort = false;
            ExecuteShort(ext);
            return;
         }
      }
   }

   //── 3. Strategy arming logic — new bar only ───────────────
   if(!IsNewBar()) return;

   const int SHIFT = 1;  // last fully closed bar
   int warmup = MathMax(InpDevLength, InpBandLookback) + InpEmaLength + 5;
   if(InpUseVolZFilter) warmup += InpAtrBaselineLen + InpAtrShortLen;
   if(Bars(_Symbol, _Period) < warmup) return;

   //── Indicator values for the just-closed bar ──
   double ema_now   = GetEMA(SHIFT);
   double ema_prev  = GetEMA(SHIFT + 1);
   if(ema_now == 0 || ema_prev == 0) return;

   double dev        = GetDeviation(InpDevLength, SHIFT);

   // Vol-Z đã được update per-tick bởi UpdateLiveVolZ() — không re-compute ở đây.
   // Chỉ cache ema/dev cho SL calc (bar-close values, cần ổn định).
   g_ema = ema_now;  g_dev = dev;
   LevelsUpdate();

   double close_now  = iClose(_Symbol, _Period, SHIFT);
   double close_prev = iClose(_Symbol, _Period, SHIFT + 1);

   //── Continuous extension (Cách C): max σ-distance mà high/low đã chạm ──
   //   trong lookback window. Bands recomputed per-bar (Pine semantics).
   double longExt  = 0.0;  // max (high - ema) / dev  trong lookback
   double shortExt = 0.0;  // max (ema - low)  / dev
   for(int i = 0; i < InpBandLookback; i++)
   {
      int    s     = SHIFT + i;
      double e_i   = GetEMA(s);
      double d_i   = GetDeviation(InpDevLength, s);
      if(d_i <= 0) continue;
      double h_bar = iHigh(_Symbol, _Period, s);
      double l_bar = iLow(_Symbol,  _Period, s);

      double longCand  = (h_bar - e_i) / d_i;
      double shortCand = (e_i - l_bar) / d_i;
      if(longCand  > longExt)  longExt  = longCand;
      if(shortCand > shortExt) shortExt = shortCand;
   }

   //── Triggers ──
   bool crossDown = (close_prev >= ema_prev) && (close_now <  ema_now); // for LONG
   bool crossUp   = (close_prev <= ema_prev) && (close_now >  ema_now); // for SHORT

   //── Signal block reset: opposite cross clears the block ──
   if(signalBlockDir > 0 && crossUp)
   {
      PrintFormat("Signal block cleared: crossUp detected → LONG unblocked");
      signalBlockDir = 0;
   }
   if(signalBlockDir < 0 && crossDown)
   {
      PrintFormat("Signal block cleared: crossDown detected → SHORT unblocked");
      signalBlockDir = 0;
   }

   //── Full-bar filter: check TRƯỚC cross ──
   // BUY: cần ít nhất 1 nến low > EMA + offset*dev trong lookback trước cross
   // SELL: cần ít nhất 1 nến high < EMA - offset*dev trong lookback trước cross
   bool fullBarOkLong  = !InpUseFullBarFilter;
   bool fullBarOkShort = !InpUseFullBarFilter;
   if(InpUseFullBarFilter)
   {
      for(int fb = 1; fb <= InpBandLookback; fb++)
      {
         int s = SHIFT + fb;
         double e_fb = GetEMA(s);
         double d_fb = GetDeviation(InpDevLength, s);
         if(e_fb <= 0 || d_fb <= 0) continue;
         double h_fb = iHigh(_Symbol, _Period, s);
         double l_fb = iLow(_Symbol,  _Period, s);

         if(!fullBarOkLong  && l_fb > e_fb + InpFullBarOffset * d_fb)
            fullBarOkLong = true;
         if(!fullBarOkShort && h_fb < e_fb - InpFullBarOffset * d_fb)
            fullBarOkShort = true;
         if(fullBarOkLong && fullBarOkShort) break;
      }
   }

   //── State machine: LONG — arm/disarm + update confirm globals ──
   if(crossDown && longExt >= InpMinEntryStd && signalBlockDir != 1 && fullBarOkLong)
   {
      barsSinceArmedLong = 0;
      armedExtLong       = longExt;
      if(InpTgNotifyArmed && InpEnableLong)
         SendTelegram(StringFormat("ARMED LONG (cross-down)\next=%.2fσ | EMA=%.5f dev=%.5f\nconfirm=%.5f (waiting %d bars)",
                      longExt, ema_now, dev, ema_now - longExt * dev, InpMaxBarsToFire));
   }
   else if(barsSinceArmedLong >= 0)
      barsSinceArmedLong++;

   // Update confirm price & window state for tick-based entry check
   g_confirmLong = (armedExtLong > 0) ? (ema_now - armedExtLong * dev) : 0;
   g_windowLong  = (barsSinceArmedLong >= 0 && barsSinceArmedLong <= InpMaxBarsToFire);

   // Window expiry → disarm
   if(barsSinceArmedLong >= 0 && barsSinceArmedLong > InpMaxBarsToFire)
   {
      barsSinceArmedLong = -1;  armedExtLong = 0;
      g_confirmLong = 0;  g_windowLong = false;
   }

   //── State machine: SHORT — mirror ──
   if(crossUp && shortExt >= InpMinEntryStd && signalBlockDir != -1 && fullBarOkShort)
   {
      barsSinceArmedShort = 0;
      armedExtShort       = shortExt;
      if(InpTgNotifyArmed && InpEnableShort)
         SendTelegram(StringFormat("ARMED SHORT (cross-up)\next=%.2fσ | EMA=%.5f dev=%.5f\nconfirm=%.5f (waiting %d bars)",
                      shortExt, ema_now, dev, ema_now + shortExt * dev, InpMaxBarsToFire));
   }
   else if(barsSinceArmedShort >= 0)
      barsSinceArmedShort++;

   g_confirmShort = (armedExtShort > 0) ? (ema_now + armedExtShort * dev) : 0;
   g_windowShort  = (barsSinceArmedShort >= 0 && barsSinceArmedShort <= InpMaxBarsToFire);

   if(barsSinceArmedShort >= 0 && barsSinceArmedShort > InpMaxBarsToFire)
   {
      barsSinceArmedShort = -1;  armedExtShort = 0;
      g_confirmShort = 0;  g_windowShort = false;
   }
}
//+------------------------------------------------------------------+
