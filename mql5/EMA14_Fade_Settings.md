# EMA14 Fade v1.83 — Hướng dẫn cài đặt thông số

## Tổng quan chiến lược

EA giao dịch theo chiến lược **mean-reversion fade**: khi giá chạy xa khỏi EMA14, chờ tín hiệu đảo chiều rồi vào lệnh ngược hướng, kỳ vọng giá quay về EMA.

**Luồng hoạt động:**
1. Giá chạm band ±Nσ (setup) → close cắt qua EMA (trigger/armed) → giá chạm band đối diện (confirm) → vào lệnh
2. Grid DCA: nếu giá tiếp tục đi ngược, mở thêm lệnh ở các level sâu hơn
3. Thoát khi PnL đạt target USD hoặc giá chạm band TP

---

## Strategy Logic

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **EMA Length** | 14 | Chu kỳ EMA. Đường trung bình động làm trục chính của chiến lược. |
| **StdDev Length** | 100 | Số nến dùng để tính độ lệch chuẩn (stdev) của `close - EMA`. Giá trị lớn hơn = band mượt hơn, ít nhạy hơn. |
| **Max bars: cross → band touch** | 2 | Sau khi close cắt EMA (armed), giá phải chạm band confirm trong vòng N nến này. Nếu hết thời gian → hủy setup. |
| **Setup lookback (N bars)** | 4 | Nhìn lại N nến gần nhất để tìm extension lớn nhất (high/low xa EMA nhất). Extension này quyết định độ sâu của confirm band. |

**Ví dụ:** EMA=14, DevLen=100, Lookback=4. Trong 4 nến gần nhất, high chạm +2.3σ → khi close cắt xuống EMA, confirm band = -2.3σ. Giá phải chạm -2.3σ trong 2 nến tiếp theo thì mới vào lệnh BUY.

---

## Sideways Filter

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Enable sideways filter** | true | Bật/tắt bộ lọc sideways. Khi bật, EA sẽ không vào lệnh trong giai đoạn thị trường đi ngang. |
| **Dev average length** | 100 | Số nến tính trung bình của stdev. Dùng để so sánh stdev hiện tại vs trung bình. |
| **Min dev ratio** | 0.7 | Ngưỡng tối thiểu: `dev_hiện_tại / trung_bình_dev`. Dưới ngưỡng này = sideways → không vào lệnh. |

**Cách hoạt động:** Nếu `dev / sma(dev, 100) < 0.7` → thị trường đang co lại, band quá hẹp → tín hiệu không đáng tin → bỏ qua.

**Tăng ratio** (ví dụ 0.9) = lọc chặt hơn, ít lệnh hơn. **Giảm** (ví dụ 0.5) = lỏng hơn, nhiều lệnh hơn.

---

## Direction Toggles

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Enable LONG** | true | Cho phép vào lệnh BUY (fade khi giá rơi). |
| **Enable SHORT** | true | Cho phép vào lệnh SELL (fade khi giá tăng). |
| **Start filter σ** | 1.0 | Extension tối thiểu (σ) để setup được chấp nhận. |

**Start filter σ (MinEntryStd):** Đây là ngưỡng quan trọng. Ví dụ đặt 1.5 → setup chỉ được armed nếu high/low đã chạm ít nhất ±1.5σ. Giá trị cao hơn = ít tín hiệu hơn nhưng chất lượng hơn.

---

## Position Sizing

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Sizing mode** | Martingale | Chọn cách tính lot: **Risk-based** hoặc **Martingale**. |
| **[RISK] Total risk %** | 2.0 | *(Chỉ dùng khi mode = Risk)* Tổng % equity rủi ro, chia đều cho các grid level. |
| **[MART] Start volume** | 0.01 | *(Chỉ dùng khi mode = Martingale)* Lot size cho level 0 (lệnh đầu tiên). |
| **[MART] Multiplier** | 1.5 | *(Chỉ dùng khi mode = Martingale)* Hệ số nhân lot: level i = start × mult^i. |
| **SL band level** | 4σ | Stop-loss đặt ở band Nσ. Chọn 2/3/4/5/6. Nếu entry extension >= SL level → EA tự bump SL lên level cao hơn. |
| **Max lot size** | 1.0 | Giới hạn cứng cho lot size mỗi level. |

**Ví dụ Martingale:** Start=0.01, Mult=1.5, 5 levels → lots = [0.01, 0.01, 0.02, 0.03, 0.05]

**Ví dụ Risk-based:** Risk=2%, 5 levels → mỗi level chịu 0.4% equity, lot tính theo khoảng cách tới SL.

---

## Grid Entry

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Enable grid entry** | true | Bật/tắt DCA grid. Tắt = chỉ vào 1 lệnh duy nhất. |
| **Grid levels** | 5 | Tổng số level (bao gồm lệnh chính). Tối đa 10. |
| **Grid spacing (σ)** | 0.5 | Khoảng cách giữa các level, tính bằng σ. |

**Cách hoạt động:**
- Level 0 = lệnh chính (market order khi confirm)
- Level 1 = entry - 0.5σ (BUY) hoặc entry + 0.5σ (SHORT)
- Level 2 = entry - 1.0σ, ...
- Mỗi level được fill bằng market order khi giá chạm (tick-based, không cần chờ nến đóng)
- Level nào nằm ngoài SL → bị bỏ qua

**Ví dụ BUY:** Entry=3240, dev=2.5, spacing=0.5σ
- L0: 3240.00
- L1: 3238.75 (3240 - 0.5×2.5)
- L2: 3237.50
- L3: 3236.25
- L4: 3235.00

---

## Take Profit

Hai chế độ TP có thể bật đồng thời — cái nào chạm trước thì đóng lệnh.

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Enable TP USD** | true | Đóng toàn bộ lệnh khi tổng floating PnL >= target USD. |
| **TP USD** | 10.0 | Mục tiêu lợi nhuận (USD). Tính tổng tất cả lệnh grid. |
| **Enable TP Band** | false | Đóng lệnh khi giá chạm band EMA ± Nσ. |
| **TP Band BUY (σ)** | 0.0 | *(Cho lệnh BUY)* Đóng khi bid >= EMA + Nσ. 0 = đóng tại EMA. |
| **TP Band SELL (σ)** | 0.0 | *(Cho lệnh SELL)* Đóng khi ask <= EMA - Nσ. 0 = đóng tại EMA. |

**Lưu ý quan trọng:**
- TP Band kiểm tra **mỗi tick**, không cần chờ nến đóng cửa
- BUY và SELL có target riêng biệt, cho phép tinh chỉnh bất đối xứng
- Ví dụ: BUY vào ở -2σ, đặt TP Band BUY = 0.3 → đóng khi giá lên tới EMA + 0.3σ
- Ví dụ: SELL vào ở +1.5σ, đặt TP Band SELL = 0 → đóng ngay khi giá chạm EMA

---

## Telegram

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Enable Telegram** | false | Bật/tắt thông báo Telegram. |
| **Bot Token** | "" | Token lấy từ @BotFather trên Telegram. |
| **Chat ID** | "" | ID chat cá nhân hoặc group (lấy từ @userinfobot). |
| **Send test on startup** | false | Gửi tin nhắn test khi khởi động EA. |
| **Notify Armed** | true | Thông báo khi setup được armed (tương đương chấm vàng trên Pine). |
| **Notify Entry** | true | Thông báo khi vào lệnh BUY/SELL. |
| **Notify TP** | true | Thông báo khi đóng lệnh do TP hit. |
| **Notify SL** | true | Thông báo khi đóng lệnh do SL hit (grid auto-reset). |
| **Notify Grid Fill** | false | Thông báo từng grid level được fill (tắt mặc định vì nhiều tin). |

**Cài đặt MT5:** Tools → Options → Expert Advisors → tick "Allow WebRequest for listed URL" → thêm `https://api.telegram.org`

**Nút trên GUI:**
- **[Test Telegram]** — gửi tin test ngay lập tức (hoạt động ngay cả khi Enable = false, chỉ cần có Token + ChatID)
- **[Close All]** — đóng toàn bộ lệnh của EA + gửi thông báo Telegram

---

## Display

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Show info panel** | true | Hiện bảng thông tin góc trái trên chart. |
| **Panel X / Y** | 16 / 28 | Vị trí panel (pixel). |
| **Draw curves** | true | Vẽ đường cong EMA và σ-band lên chart (giống TradingView). |
| **Draw bars** | 300 | Số nến vẽ lại phía trước. Tăng = vẽ xa hơn, tốn hơn. |
| **Draw ±1σ** | false | Vẽ band ±1σ (xanh/đỏ, nét chấm). |
| **Draw ±2σ** | true | Vẽ band ±2σ. |
| **Draw ±3σ** | false | Vẽ band ±3σ. |
| **Draw ±4σ** | true | Vẽ band ±4σ. |
| **Draw SL band** | true | Vẽ band SL (hồng, nét gạch-chấm). |
| **Draw grid levels** | true | Vẽ đường ngang tại các grid level khi grid active (vàng, nét gạch). |

**Hiệu năng:** Với 300 bars và bật EMA + 2 bands + SL = khoảng 1800 objects. MT5 xử lý tốt. Nếu lag, giảm Draw bars xuống 100-150.

---

## Misc

| Thông số | Mặc định | Mô tả |
|---|---|---|
| **Magic number** | 20260410 | Số định danh EA. Nếu chạy nhiều EA trên cùng symbol, mỗi cái cần magic khác nhau. |
| **Comment** | "EMA14_Fade" | Comment gắn vào mỗi lệnh. Grid level thêm hậu tố `_G0`, `_G1`, ... |
| **Max slippage** | 30 | Slippage tối đa chấp nhận khi mở lệnh (points). XAUUSD: 30 points ≈ $0.30. |

---

## Gợi ý cài đặt theo phong cách

### Conservative (ít lệnh, rủi ro thấp)
```
MinEntryStd = 2.0      ← chỉ vào khi extension >= 2σ
MinDevRatio = 0.9      ← lọc sideways chặt
GridLevels = 3         ← ít DCA
SL = 5σ hoặc 6σ       ← SL rộng
TP USD = 5.0           ← chốt lời sớm
StartVolume = 0.01     ← lot nhỏ
GridMult = 1.0         ← lot đều nhau
```

### Aggressive (nhiều lệnh, rủi ro cao hơn)
```
MinEntryStd = 1.0      ← vào từ 1σ
MinDevRatio = 0.5      ← lọc lỏng
GridLevels = 7         ← DCA sâu
SL = 4σ               ← SL vừa
TP USD = 20.0          ← để chạy xa hơn
StartVolume = 0.02     ← lot lớn hơn
GridMult = 1.5         ← tăng lot mạnh ở level sâu
```

### Chỉ BUY (dip buying)
```
EnableLong = true
EnableShort = false
TP BandBuy = 0.3       ← chốt gần EMA
```

### Chỉ SELL (rally fading)
```
EnableLong = false
EnableShort = true
TP BandSell = 0.5      ← chốt cách EMA 0.5σ
```
