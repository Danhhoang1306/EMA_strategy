# EMA14 Fade — Hướng dẫn cài đặt thông số

Chiến lược **mean-reversion fade**: khi giá chạy xa khỏi EMA14, chờ tín hiệu đảo chiều rồi vào lệnh ngược hướng, kỳ vọng giá quay về EMA. Khi bị kéo sâu → mở thêm grid DCA.

---

## ⚡ Cài đặt nhanh (3 preset)

Copy nguyên các dòng dưới đây nếu bạn chưa biết bắt đầu từ đâu. XAUUSD M5 mặc định.

### 1. Thử nghiệm an toàn (lot cố định, risk thấp)

```
Grid Entry:
  enable grid entry            = true
  select mode                  = std mode
  Grid levels                  = 3

std mode metric:
  grid spacing (by std)        = 0.5

Volume multiplier:
  select volume mutil mode     = Arithmetic progression
  start volume                 = 0.01
  Arithmetic progression       = 0.00      ← lot mọi level = 0.01

Toltal in risk percent metric:
  SL band level                = 4σ

Take Profit:
  Enable TP by floating PnL (USD) = true
  TP USD                       = 3.0
```
**Nghĩa là:** 3 grid cách nhau 0.5σ, mỗi level 0.01 lot, SL ở 4σ, chốt lời khi lãi 3 USD.

### 2. Martingale cổ điển (lot nhân đôi mỗi level)

```
select volume mutil mode       = Geometric progression
start volume                   = 0.01
Geometric progression          = 2.0       ← lots = 0.01, 0.02, 0.04, 0.08, 0.16
Grid levels                    = 5
grid spacing (by std)          = 0.5
SL band level                  = 6σ        ← đủ xa để grid không bị cắt sớm
```

### 3. Risk-based (auto size lot theo balance)

```
select volume mutil mode       = total inrisk percent
toltal risk % balance          = 2.0       ← rủi ro tối đa 2% balance
SL band level                  = 5σ        ← BẮT BUỘC ≠ No SL
commision per lot              = 0.0       ← điền theo broker
Grid levels                    = 5
grid spacing (by std)          = 0.5
```
EA sẽ tự tính lot mỗi level sao cho nếu SL hit, tổng lỗ = 2% balance.

---

## 📋 Giải thích từng thông số

### Strategy Logic — Khung logic chính

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **EMA Length** | 14 | Chu kỳ đường EMA (trục chính). |
| **StdDev Length** | 100 | Số nến tính độ lệch chuẩn band. Lớn hơn = band mượt, ít nhiễu. |
| **Max bars: cross → band touch** | 2 | Sau khi cross EMA, giá phải chạm band confirm trong N nến, hết thì hủy. |
| **Setup lookback** | 4 | Nhìn N nến gần nhất để lấy độ nhô (extension) lớn nhất. |

**Ví dụ:** Trong 4 nến gần đây, high chạm +2.3σ. Khi giá cắt xuống EMA, confirm cần low chạm -2.3σ trong 2 nến tiếp để fire BUY.

---

### Vol Z-Score Filter — Chặn vào lệnh khi volatility sốc

Chặn những thời điểm thị trường biến động bất thường (tin tức, spike).

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable volatility z-score filter** | true | Bật/tắt filter |
| **Short ATR length** | 3 | ATR ngắn (volatility hiện tại) |
| **Baseline length** | 100 | So sánh ATR ngắn với N nến trước |
| **Max Z-score threshold** | 2.0 | Block khi volatility hiện tại > mean + 2×stdev |
| **Log when rejected** | true | Ghi log khi bị chặn |

> **Giữ nguyên** nếu không rõ. 2.0 là ngưỡng hợp lý.

---

### Full-Bar Filter — Yêu cầu nến đầy đủ trước khi cross

Tránh false signal khi giá chỉ chạm EMA rồi bật ra ngay.

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable full-bar filter** | true | Bật/tắt |
| **Full-bar offset (σ)** | 0.3 | Yêu cầu có ít nhất 1 nến body nằm hoàn toàn trên/dưới EMA±0.3σ trước khi cross. |

---

### Session Filter — Chặn vào lệnh theo khung giờ

Tránh thanh khoản thấp quanh giờ mở/đóng cửa.

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable session-time filter** | false | Bật/tắt (default OFF) |
| **Skip entries within N min AFTER open** | 60 | Không vào lệnh trong N phút đầu sau mở cửa |
| **Skip entries within N min BEFORE close** | 60 | Không vào lệnh trong N phút cuối trước đóng cửa |
| **Log when rejected** | true | Ghi log khi bị chặn |

EA đọc giờ giao dịch của symbol từ broker. XAUUSD/FX 24/5 thường chỉ có 1 session dài → lọc hữu ích cho rìa thứ Hai sáng & thứ Sáu chiều.

---

### Direction Toggles — Chọn hướng giao dịch

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable LONG entries** | true | Cho phép vào BUY |
| **Enable SHORT entries** | true | Cho phép vào SELL |
| **Start filter σ** | 1.0 | Chỉ arm setup nếu giá đã nhô ≥ 1σ. Cao hơn = chặt hơn, ít signal hơn. |

---

### Grid Entry — Cài đặt lưới DCA

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **enable grid entry** | true | Bật grid. Tắt = chỉ 1 lệnh đơn |
| **select mode** | std mode | Chọn cách đo khoảng cách grid: `std mode` (theo σ) hoặc `fixed point mode` (theo point cố định) |
| **Grid levels** | 5 | Tổng số lệnh (gồm lệnh chính). 2-10. |

#### Chọn mode thế nào?

- **std mode:** khoảng cách co giãn theo volatility. Ưu điểm: tự thích nghi. Dùng khi không chắc volatility.
- **fixed point mode:** khoảng cách cứng (ví dụ 100 point = $1 với XAUUSD). Ưu điểm: dễ dự đoán. Dùng khi symbol có volatility ổn định hoặc muốn kiểm soát chính xác.

---

### std mode metric (chỉ dùng khi chọn `std mode`)

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **grid spacing (by std)** | 0.5 | Mỗi grid cách nhau N×σ. Ví dụ 0.5σ, dev=2$ → gap=1$. |

**Cách tính gap thực tế:** `gap = grid spacing × dev_hiện_tại`

---

### fixed point mode metric (chỉ dùng khi chọn `fixed point mode`)

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **fixed point grid (point)** | 100 | Mỗi grid cách nhau N point. XAUUSD: 100pt = $1; EURUSD: 100pt = 10 pip. |

---

### Volume multiplier — Tính lot cho từng grid

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **select volume mutil mode** | Geometric progression | 3 cách tính lot: Arithmetic / Geometric / total inrisk percent |
| **start volume** | 0.01 | Lot cho level 0 (lệnh chính). Dùng trong Arith & Geom. |
| **Arithmetic progression** | 0.02 | Hệ số cộng — dùng khi chọn Arith |
| **Geometric progression** | 1.5 | Hệ số nhân — dùng khi chọn Geom |

#### 3 công thức lot

| Mode | Công thức | Ví dụ (start=0.01) |
|---|---|---|
| **Arithmetic progression** | `lot[i] = start + i × coeff` | coeff=0.02 → 0.01, 0.03, 0.05, 0.07, 0.09 |
| **Geometric progression** | `lot[i] = start × coeff^i` | coeff=1.5 → 0.01, 0.015, 0.023, 0.034, 0.051 |
| **total inrisk percent** | `lot[i] = risk_per_level / cost` | auto-size từ balance, xem section dưới |

---

### Toltal in risk percent metric (liên quan RISK mode + SL)

| Thông số | Mặc định | Ý nghĩa | Bắt buộc khi? |
|---|---|---|---|
| **toltal risk % balance** | 2.0 | Tổng rủi ro % balance khi SL hit | RISK mode |
| **SL band level** | 4σ | Đặt SL ở EMA ± Nσ. `No SL` = không có SL | Mọi mode (nên có) |
| **commision per lot** | 0.0 | Commission 1 chiều / lot (tính vào công thức risk) | RISK mode |

#### Cách đọc SL band level

- **2σ–3σ:** SL chặt, grid bị cắt sớm nếu giá đi xa. Dùng khi ít level.
- **4σ–5σ:** cân bằng. Mặc định cho 5 levels.
- **6σ:** SL rộng, grid hiếm khi bị cắt nhưng lỗ nếu hit sẽ lớn.
- **No SL:** KHÔNG khuyến nghị trừ khi bạn hiểu rõ.

#### RISK mode hoạt động thế nào?

`risk_per_level = toltal_risk% / số_levels_armed`

Mỗi level được size lot sao cho nếu SL hit từ level đó, lỗ đúng bằng `risk_per_level × balance`. Level càng gần SL → lot càng lớn (để đạt cùng mức rủi ro).

**Ví dụ:** Balance=$10,000, risk=2%, 5 levels → 0.4%/level = $40 loss/level nếu SL hit.

---

### Take Profit

Có thể bật cả 2, **cái nào hit trước thì chốt**.

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable TP by floating PnL (USD)** | true | Chốt khi tổng PnL floating đạt target |
| **TP USD** | 10.0 | Target USD. Đơn giản, ai cũng hiểu. |
| **Enable TP by price touching EMA±Nσ** | false | Chốt khi giá chạm band |
| **TP BAND Buy target σ** | 0.0 | BUY chốt khi giá lên tới EMA + Nσ. 0 = tại EMA, 0.3 = EMA + 0.3σ |
| **TP BAND Sell target σ** | 0.0 | SELL chốt khi giá xuống tới EMA − Nσ |

> **Khuyến nghị cho người mới:** chỉ bật `TP USD = 5-15$`. Đơn giản, dễ dự đoán.

---

### Telegram (tùy chọn)

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Enable Telegram notifications** | false | Bật/tắt |
| **Bot Token** | "" | Token từ @BotFather |
| **Chat ID** | "" | ID user/group |
| **Send test on startup** | false | Gửi tin test khi khởi động EA |
| **Notify armed** | true | Báo khi setup armed (chờ confirm) |
| **Notify entry** | true | Báo khi vào lệnh |
| **Notify TP** | true | Báo khi chốt TP |
| **Notify SL** | true | Báo khi SL hit |
| **Notify grid fill** | false | Báo mỗi level fill (rất nhiều noise) |

---

### Display — Hiển thị trên chart

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Show info panel** | true | Hiển thị panel thông tin góc trái |
| **Panel X / Y** | 16 / 28 | Vị trí panel (pixel) |
| **Draw EMA & σ-band curves** | true | Vẽ EMA + các band |
| **Draw N bars back** | 300 | Chỉ vẽ N nến gần đây |
| **Draw ±1σ / ±2σ / ±3σ / ±4σ** | tuỳ | Bật band nào muốn thấy |
| **Draw SL band** | true | Vẽ band SL để biết mức cắt |

---

### Misc

| Thông số | Mặc định | Ý nghĩa |
|---|---|---|
| **Magic number** | 20260410 | Số phân biệt lệnh của EA này. **Đổi nếu chạy nhiều EA cùng chart** |
| **Comment** | "EMA14_Fade" | Tag lệnh |
| **Max slippage (points)** | 30 | Slippage tối đa khi fill market |

---

## 🎯 Tips chung

1. **Luôn backtest** với bộ tham số mới trước khi chạy live.
2. **Bắt đầu với preset #1** (safe) trên demo 1-2 tuần rồi mới tăng risk.
3. **SL phải đủ rộng** cho số grid levels: `SL σ ≥ startFilter + (levels−1) × gridSpacing`. EA sẽ tự bump SL nếu quá chặt.
4. **Magic number khác nhau** nếu chạy EA trên nhiều pair/timeframe cùng lúc.
5. **RISK mode yêu cầu SL** — nếu chọn `No SL` với RISK mode, EA sẽ từ chối khởi động.
6. **Kiểm tra log** ở tab "Experts" của MT5 — EA in lý do reject rất rõ.

---

## 🔧 Công thức SL auto-bump

Nếu SL bạn chọn quá gần grid sâu nhất, EA sẽ tự đẩy SL ra xa hơn. Công thức:

```
grid_extent_σ = (levels - 1) × spacing_σ       # STD mode
              = (levels - 1) × pts × _Point/dev # POINT mode

sl_min_required = entryExt + grid_extent_σ + 1.0
```

Ví dụ: 5 levels, 0.5σ spacing, entry extension 1.5σ → cần SL ≥ `1.5 + 2.0 + 1.0 = 4.5σ`. Nếu bạn chọn 4σ → bump lên 5σ.
