# EMA14 Mean-Reversion Fade Strategy

Fade chiến lược trên **XAUUSD M5** dựa trên mean reversion về EMA14 sau các đợt giá nhô xa khỏi trung bình. Repo chứa 2 triển khai song song: **MQL5 (MetaTrader 5 EA)** để chạy thực, và **Pine Script (TradingView)** để visualize + backtest trực quan.

## Mục lục

- [Logic chiến lược](#logic-chiến-lược)
- [Cấu trúc repo](#cấu-trúc-repo)
- [MQL5 — MetaTrader 5 EA](#mql5--metatrader-5-ea)
- [Pine Script — TradingView](#pine-script--tradingview)
- [Filters](#filters)
- [Grid Entry & Sizing](#grid-entry--sizing)
- [Take Profit / Stop Loss](#take-profit--stop-loss)
- [Cài đặt & sử dụng](#cài-đặt--sử-dụng)
- [Version history](#version-history)

---

## Logic chiến lược

### Ý tưởng cốt lõi

Giả định: giá dao động quanh EMA14. Sau một đợt giá "overshoot" (nhô xa khỏi EMA14 bao nhiêu σ đó), xác suất giá quay về EMA cao hơn xác suất tiếp tục trend. Chiến lược:

1. **Detect overshoot** (setup arm): trong lookback window, giá high/low đã chạm ít nhất `minEntryStd × σ` khỏi EMA.
2. **Wait cross EMA** (trigger): giá xuyên qua EMA theo chiều ngược (cross down cho LONG setup, cross up cho SHORT).
3. **Wait confirm touch** (entry): sau cross, giá quay lại chạm band `ext × σ` ở phía đối diện → vào lệnh fade về EMA.

**"Cách C" (continuous tier)**: `ext` không cố định mà chính bằng σ-extension thực tế đã xảy ra. Ví dụ bar đã nhô +2.3σ → confirm entry cần giá chạm −2.3σ (đối xứng), không phải −2σ hay −3σ rời rạc.

### Công thức

```
ema    = EMA(close, 14)
dev    = population stdev(close − ema, 100)   // biased stdev, match Pine ta.stdev

longExt  = max over lookback of (high_i − ema_i) / dev_i
shortExt = max over lookback of (ema_i − low_i)  / dev_i

Arm LONG:   crossDown (close breaks below EMA) AND longExt  ≥ minEntryStd
Arm SHORT:  crossUp   (close breaks above EMA) AND shortExt ≥ minEntryStd

Confirm LONG:  low  ≤ ema − armedExt × dev
Confirm SHORT: high ≥ ema + armedExt × dev

Window: giá phải chạm confirm trong maxBarsToFire bars kể từ cross, không thì setup hủy.
```

---

## Cấu trúc repo

```
EMA_strategy/
├── mql5/
│   ├── EMA14_Fade.mq5              ← Main EA (v1.94)
│   ├── EMA14_Fade.md               ← Deep-dive docs
│   ├── EMA14_Fade_Settings.md      ← Input parameters guide
│   └── TVAgentFeed.mq5             ← TradingView webhook bridge
├── pine/
│   ├── ema14_fade.pine             ← Original (sideways filter)
│   ├── ema14_fade_volz.pine        ← Current (Vol-Z filter) ★
│   ├── vol_zscore_filter.pine      ← Companion sub-pane indicator
│   └── ema_cross.pine              ← Simple cross detection experiment
├── .gitignore
└── README.md
```

★ = version hiện tại được khuyến nghị dùng.

---

## MQL5 — MetaTrader 5 EA

**File chính**: [EMA14_Fade.mq5](mql5/EMA14_Fade.mq5) — v1.94

### Kiến trúc

**3 layer chính trong `OnTick`:**

1. **State management** (auto-reset grid nếu SL hit, clear state cũ).
2. **Per-tick checks**:
   - `UpdateLiveVolZ()` — compute Vol-Z filter sử dụng bar đang form (shift=0).
   - `PanelUpdate()` — refresh GUI panel.
   - TP check (USD hoặc Band).
   - Entry trigger: giá chạm confirm → `ExecuteLong/Short`.
3. **Per-new-bar strategy logic**: compute dev, longExt/shortExt, crossDown/Up, full-bar filter, arm setup.

**Dual CTrade instances:**
- `trade` (sync) — dùng cho L0 market entry, chờ broker confirm fill.
- `tradeAsync` (`SetAsyncMode(true)`) — dùng cho L1..N pending limits + toàn bộ close/delete. Fire-and-forget, không block OnTick.

**Order flow khi signal fire:**
1. L0 `trade.Buy/Sell` SYNC — chờ fill confirm (~50-200ms).
2. L1..L4 `tradeAsync.BuyLimit/SellLimit` ASYNC — fire gần đồng thời (~5ms total).

**Order flow khi TP/SL hit:**
1. `CloseAllPositions()` với dedup guard (cooldown 2s).
2. `DeletePendingOrders()` async trước.
3. `PositionClose()` async cho từng ticket — broker xử lý song song, fill gần như đồng thời.

### File phụ

- [EMA14_Fade.md](mql5/EMA14_Fade.md) — chi tiết logic, formula, edge cases
- [EMA14_Fade_Settings.md](mql5/EMA14_Fade_Settings.md) — mô tả từng input parameter
- [TVAgentFeed.mq5](mql5/TVAgentFeed.mq5) — EA phụ nhận signal từ TradingView webhook (nếu muốn copy-trade từ Pine alert)

---

## Pine Script — TradingView

### File khuyến nghị

1. **[ema14_fade_volz.pine](pine/ema14_fade_volz.pine)** (overlay trên chart giá)
   - Hiển thị EMA + σ bands, marker entry/SL, grid levels.
   - Vol-Z filter per-tick (bar-form mode, khớp MQL5).
   - Dấu **X đỏ** = full-bar filter reject.
   - Dấu **X xanh** = Vol-Z filter reject.
   - Bg đỏ = Vol-Z đang block vùng đó.

2. **[vol_zscore_filter.pine](pine/vol_zscore_filter.pine)** (sub-pane, `overlay=false`)
   - Visualize ATR ngắn + baseline mean ± N·σ (ATR bands mode).
   - Hoặc Z-score + threshold line (Z-score mode).
   - Info table góc phải: ATR, mean, stdev, Z, status.
   - Alert khi regime chuyển HIGH ↔ NORMAL.

### Files khác

- [ema14_fade.pine](pine/ema14_fade.pine) — version cũ với sideways filter (dev/devAvg ratio). Giữ để so sánh, không dùng nữa.
- [ema_cross.pine](pine/ema_cross.pine) — experiment sớm, chỉ detect cross EMA.

### Khớp với MQL5

Pine là source of truth cho visual. MQL5 port 1-1 logic:
- `ta.stdev(close − ema, devLen)` → `GetDeviation()` (population stdev)
- `ta.atr(atrShortLen)` → `iATR()` + `GetAtrShort()`
- `ta.sma + ta.stdev` cho ATR baseline → `GetAtrZScore()`
- Continuous tier extension → loop `longExt/shortExt` trong OnTick new-bar block

---

## Filters

### 1. Vol Z-Score Filter (mới, thay sideways filter cũ)

**Mục đích**: chặn entry khi volatility spike bất thường (tin ra, manipulation, gap news).

```
atrShort  = ATR(3)                              // nhạy để bắt shock
atrMean   = SMA(atrShort, 100)
atrStd    = stdev(atrShort, 100)
atrZ      = (atrShort − atrMean) / atrStd
Block khi atrZ ≥ threshold (default 2.0)
```

- **MQL5**: tính **per-tick** với `shift=0` (bar đang form). Spike chạm ngay sẽ block.
- **Pine**: realtime tick cũng với bar đang form → match MQL5.
- **Behavior**: nếu entry bị block → **hủy hẳn armed state**, không chờ volZ giảm. Cần cross EMA mới để arm lại.

Inputs: `InpAtrShortLen`, `InpAtrBaselineLen`, `InpVolZThreshold`, `InpLogVolZReject`.

### 2. Full-Bar Filter

**Mục đích**: tránh arm trên bar chỉ "vừa kịp" cross EMA (noise cross).

Trước khi accept `crossDown`, cần có ít nhất 1 bar trong lookback mà `low > EMA + offset × σ` (cho LONG). Đảm bảo giá đã **thực sự** ở trên EMA trước khi cross xuống. Tương tự mirror cho SHORT.

Inputs: `InpUseFullBarFilter`, `InpFullBarOffset`.

### 3. Min Entry σ Gate

Setup chỉ arm nếu `longExt ≥ minEntryStd`. Default 1.0σ. Không trade khi overshoot không đủ sâu.

### 4. Direction Toggles

`InpEnableLong`, `InpEnableShort`. Có thể tắt 1 chiều khi chỉ muốn fade 1 hướng.

---

## Grid Entry & Sizing

### Grid levels

- L0 = main entry tại confirm price (market order sync).
- Li = entry ± `i × InpGridSpacingStd × dev` về phía adverse (LONG = xuống sâu hơn).
- Max 10 levels (default 5).
- Level nào vượt/gần SL quá mức (< 1 spacing từ SL) → bị skip.

### Sizing modes

**`SIZING_MARTINGALE`** (default): `lot[i] = start × mult^i`. Risky nhưng grid càng sâu càng đỡ lỗ nhanh.

**`SIZING_RISK`**: total `InpRiskPercent%` của account chia đều cho N levels, mỗi lệnh tính theo Position Sizer formula (EarnForex style).

### SL auto-bump

Nếu chọn `SL_StdLevel = 4` (4σ) nhưng entry extension = 3.5σ và grid cần đi xuống 4.5σ → SL tự bump lên 5σ (`ceil(maxLevelExt + 1e-6)`). Đảm bảo SL luôn nằm ngoài grid cuối.

---

## Take Profit / Stop Loss

### TP modes (có thể enable cả 2, hit trước thắng)

- **TP_USD**: tổng floating PnL (tất cả grid positions + swap) ≥ `InpTP_USD` → close all.
- **TP_BAND**: giá chạm EMA ± `N × σ` (BUY target và SELL target riêng).

### SL

- Cùng 1 SL price cho toàn grid.
- Nếu broker đóng 1 position (SL hit) → EA detect và kill toàn bộ grid còn lại + delete pendings.
- Auto-reset grid state + set `signalBlockDir` → chặn arm cùng chiều cho đến khi có cross ngược.

---

## Cài đặt & sử dụng

### MQL5 (MetaTrader 5)

1. Copy [EMA14_Fade.mq5](mql5/EMA14_Fade.mq5) → `<MT5_Data>/MQL5/Experts/`.
2. Optional: copy [TVAgentFeed.mq5](mql5/TVAgentFeed.mq5) nếu dùng webhook từ TV.
3. Mở MetaEditor, compile (F7).
4. Attach EA vào chart XAUUSD M5.
5. Mở **AutoTrading** và trong EA settings bật **Allow live trading**.
6. Cấu hình inputs theo [EMA14_Fade_Settings.md](mql5/EMA14_Fade_Settings.md).
7. (Optional) Bật Telegram: setup bot qua @BotFather, thêm URL `https://api.telegram.org` vào `Tools > Options > Expert Advisors > Allow WebRequest`.

### Pine Script (TradingView)

1. Mở TradingView → Pine Editor (phía dưới chart).
2. Copy nội dung [ema14_fade_volz.pine](pine/ema14_fade_volz.pine) → paste vào editor.
3. Save (tên bất kỳ) → "Add to chart".
4. Mở Pine Editor tab mới, paste [vol_zscore_filter.pine](pine/vol_zscore_filter.pine) → Save → Add to chart.
5. Đặt cùng giá trị `atrShortLen`, `atrBaselineLen`, `volZThreshold` ở cả 2 indicators.
6. Tùy chỉnh alert nếu muốn nhận signal qua email/app/webhook.

### Alignment MQL5 ↔ Pine

Để MQL5 và Pine cùng produce signal giống nhau:

| Input | MQL5 | Pine |
|---|---|---|
| EMA length | `InpEmaLength=14` | `emaLen=14` |
| Dev length | `InpDevLength=100` | `devLen=100` |
| Max bars to fire | `InpMaxBarsToFire=2` | `maxBarsToFire=4` ⚠️ |
| Band lookback | `InpBandLookback=4` | `bandLookback=4` |
| Min entry σ | `InpMinEntryStd=1.0` | `minEntryStd=1.0` |
| Full-bar offset | `InpFullBarOffset=0.3` | `fullBarOffsetStd=0.3` |
| ATR short len | `InpAtrShortLen=3` | `atrShortLen=3` |
| ATR baseline | `InpAtrBaselineLen=100` | `atrBaselineLen=100` |
| Vol-Z threshold | `InpVolZThreshold=2.0` | `volZThreshold=2.0` |

⚠️ `maxBarsToFire` có thể khác giữa MQL5 và Pine do mô hình bar khác nhau (MQL5 bar-close eval vs Pine intra-bar). Điều chỉnh cho phù hợp khi cần.

---

## Version history

| Version | Thay đổi chính |
|---|---|
| v1.94 | Revert paced queue, giữ L0 sync + L1..L4 async (in-order single pass) |
| v1.93 | Paced queue for broker rate limit (rollback về v1.94) |
| v1.92 | L1..L4 pending async qua `tradeAsync` |
| v1.91 | Vol-Z filter per-tick với `shift=0` |
| v1.90 | Async close/delete hàng loạt qua `SetAsyncMode(true)` |
| v1.89 | Port Vol Z-Score filter từ Pine, bỏ sideways filter cũ |
| v1.88 và trước | Sideways filter (dev/devAvg ratio), single grid submission sync |

---

## License

Private/personal use. Không có warranty. Trade at your own risk.
