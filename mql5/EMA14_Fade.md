# EMA14 Mean-Reversion Fade

Chiến lược fade mean-reversion dựa trên EMA14 và band stdev. Hoạt động cả 2 chiều LONG và SHORT trên `XAUUSD M5`.

## Ý tưởng

Khi giá XAUUSD bị over-extend ra khỏi EMA14 (chạm upper band rồi cắt mạnh xuống, hoặc chạm lower band rồi cắt mạnh lên), thường có xu hướng bật lại về EMA. Chiến lược này bắt cú bật lại đó.

**Đặc trưng "momentum mạnh"** không đo bằng chỉ báo riêng — mà đo bằng **tốc độ chạm band đối diện**: nếu cú phá EMA đủ mạnh thì giá sẽ chạm band đối diện trong vòng tối đa 4 nến.

## Logic chiến lược

### LONG (fade panic sell)

| Bước | Điều kiện |
|---|---|
| 1. Setup | Trong 10 nến gần nhất, `high` đã chạm `upper = EMA14 + 1σ` |
| 2. Trigger | `close` cắt **xuống** xuyên EMA14 |
| 3. Confirm | Trong vòng tối đa 4 nến từ trigger, `low` chạm `lower = EMA14 − 1σ` |
| 4. Entry | BUY @ market |
| 5. SL | `EMA14 − Nσ` (N chọn từ dropdown: 2/3/4) |
| 6. Exit | Floating PnL ≥ `InpTP_USD` |

### SHORT (fade panic buy — mirror đối xứng)

| Bước | Điều kiện |
|---|---|
| 1. Setup | Trong 10 nến gần nhất, `low` đã chạm `lower = EMA14 − 1σ` |
| 2. Trigger | `close` cắt **lên** xuyên EMA14 |
| 3. Confirm | Trong vòng tối đa 4 nến từ trigger, `high` chạm `upper = EMA14 + 1σ` |
| 4. Entry | SELL @ market |
| 5. SL | `EMA14 + Nσ` (N chọn từ dropdown: 2/3/4) |
| 6. Exit | Floating PnL ≥ `InpTP_USD` |

### Ghi chú quan trọng

- **σ ở đây = `stdev(close − EMA14, 14)`** — độ lệch chuẩn của khoảng cách giá tới EMA, không phải stdev của close. Đây là cách "Bollinger band quanh EMA" đúng nghĩa.
- **Position sizing tự thích nghi theo volatility:** vol cao → SL distance lớn → lot nhỏ; vol thấp → SL distance hẹp → lot to. Risk mỗi trade luôn = `InpRiskPercent`% vốn.
- **No-hedging:** chỉ 1 vị thế tại 1 thời điểm. Nếu LONG và SHORT cùng trigger 1 bar, **LONG ưu tiên** (xử lý trước trong code).
- **Bar-close based:** logic chỉ chạy khi 1 nến M5 đóng. Floating-PnL TP check chạy mỗi tick.

## Inputs

### Strategy Logic
| Input | Default | Mô tả |
|---|---|---|
| `InpEmaLength` | 14 | Chu kỳ EMA |
| `InpDevLength` | 14 | Chu kỳ tính stdev |
| `InpStdMult` | 1.0 | Multiplier band trigger entry |
| `InpMaxBarsToFire` | 4 | Số nến tối đa từ cross → chạm band đối diện |
| `InpBandLookback` | 10 | Số nến lookback cho setup |

### Sideways Filter
| Input | Default | Mô tả |
|---|---|---|
| `InpUseSidewaysFilter` | true | Bật/tắt filter sideways |
| `InpDevAvgLen` | 50 | Chu kỳ SMA của `dev` để so sánh |
| `InpMinDevRatio` | 0.7 | Ngưỡng `dev / avg_dev`. Dưới ngưỡng này coi là sideways → skip entry |

**Nguyên lý:** khi giá đi ngang, stdev `dev` co lại nhỏ hơn trung bình gần đây. Nếu `dev / sma(dev, 50) < 0.7` → volatility đang co rút → bỏ qua signal để tránh trade false trong sideways.

### Direction Toggles
| Input | Default | Mô tả |
|---|---|---|
| `InpEnableLong` | true | Bật LONG entries |
| `InpEnableShort` | true | Bật SHORT entries |
| `InpMinEntryStd` | 1.0 | **Float tự nhập** — min setup extension (σ). Setup chỉ được arm nếu high/low chạm ít nhất `±InpMinEntryStd * σ`. **Continuous ladder**: confirm target = chính độ nhô thực tế (không làm tròn). Ví dụ: min=1.5, touched +2.3σ → confirm cần `low ≤ EMA − 2.3σ`. |

### Position Sizing
| Input | Default | Mô tả |
|---|---|---|
| `InpSizingMode` | `SIZING_MARTINGALE` | **Dropdown:** `SIZING_RISK` (chia đều total risk %) hoặc `SIZING_MARTINGALE` (start volume × multiplier^level) |
| `InpRiskPercent` | 2.0 | [RISK mode] Total risk per signal (% equity), chia đều cho armed levels |
| `InpStartVolume` | 0.01 | [MARTINGALE mode] Lot size cho level 0 (main entry) |
| `InpGridMult` | 1.5 | [MARTINGALE mode] Hệ số nhân per level. `lot[i] = start × mult^i`. `1.0` = same lot mọi level, `2.0` = classic martingale double-down |
| `InpSL_StdLevel` | 4σ | **Dropdown:** SL band level (2σ..6σ). Auto-bump nếu ≤ entry tier hoặc không đủ rộng cho toàn grid |
| `InpMaxLotSize` | 1.0 | Cap cứng lot size (mỗi level) |

**Ví dụ Martingale** với `start=0.01, mult=1.5, 5 levels`:
| Level | Lot (raw) | Normalized |
|---|---|---|
| L0 | 0.01 × 1.5⁰ = 0.01 | 0.01 |
| L1 | 0.01 × 1.5¹ = 0.015 | 0.01 (floor theo volume_step 0.01) |
| L2 | 0.01 × 1.5² = 0.0225 | 0.02 |
| L3 | 0.01 × 1.5³ = 0.03375 | 0.03 |
| L4 | 0.01 × 1.5⁴ = 0.05063 | 0.05 |
| **Total** | | **0.12 lot** |

Nếu `mult=2.0`: 0.01 / 0.02 / 0.04 / 0.08 / 0.16 = **0.31 lot total** — cẩn thận, exposure ×31 so với start.

### Grid Entry (DCA)
| Input | Default | Mô tả |
|---|---|---|
| `InpUseGridEntry` | true | Bật/tắt grid entry |
| `InpGridLevels` | 5 | Tổng số level (gồm level 0 = main entry). Max 10 |
| `InpGridSpacingStd` | 0.5 | Khoảng cách giữa các level, tính theo σ |

**Cách hoạt động:**
- Level 0 = main entry tại giá trigger, mở market ngay khi signal fire
- Level i = level 0 ∓ `i * spacing * dev` (adverse direction)
- Mỗi level nhận risk = `InpRiskPercent / gridLevels`
- SL chung cho toàn grid, auto-bump để nằm ngoài level cuối cùng
- Level bị skip nếu price nằm ngoài SL
- Grid fill theo tick: check mỗi tick xem giá chạm level nào chưa filled
- Khi bất kỳ position nào đóng (TP hoặc SL) → toàn bộ grid đóng và reset state

### Take Profit (2 độc lập, whichever hits first)
| Input | Default | Mô tả |
|---|---|---|
| `InpUseTP_USD` | true | Bật/tắt TP by floating PnL |
| `InpTP_USD` | 10.0 | Đóng khi **total** floating PnL của toàn grid ≥ giá trị này |
| `InpUseTP_Band` | false | Bật/tắt TP by price touching band |
| `InpTP_BandStd` | 0.0 | **Float tự nhập** — target band theo σ. Ví dụ: 0 = EMA, 0.5 = EMA ± 0.5σ, 1.3 = EMA ± 1.3σ. LONG đóng khi `bid >= ema + N*σ`, SHORT khi `ask <= ema - N*σ`. Chỉ đóng khi đang lời (guard chống exit tức thì). |

**Có thể bật cả 2 cùng lúc** — whichever điều kiện hit trước thì đóng. Ví dụ:
- `InpUseTP_USD=true, InpTP_USD=$20` + `InpUseTP_Band=true, InpTP_BandStd=0.5`
- → Grid đóng khi total PnL đạt $20 **HOẶC** giá chạm EMA ± 0.5σ (tuỳ cái nào trước)

Có thể tắt cả 2 (`InpUseTP_USD=false, InpUseTP_Band=false`) → grid không có TP, chỉ thoát khi SL hit. Không khuyến khích.

### Misc
| Input | Default | Mô tả |
|---|---|---|
| `InpMagic` | 20260410 | Magic number |
| `InpComment` | EMA14_Fade | Comment trên lệnh |
| `InpSlippagePoints` | 30 | Slippage cho phép (points) |

## Files

| File | Mục đích |
|---|---|
| [`EMA14_Fade.mq5`](EMA14_Fade.mq5) | EA chính cho MT5 (LONG + SHORT) |
| [`../src/pine_scripts/ema14_fade.pine`](../src/pine_scripts/ema14_fade.pine) | Pine indicator để visualize tín hiệu LONG trên TradingView (dùng cho bước verify trước khi backtest) |

## Cách backtest

1. **Copy** `EMA14_Fade.mq5` vào `<MT5_Data_Folder>/MQL5/Experts/`
2. Mở **MetaEditor** (F4) → mở file → bấm **Compile** (F7), phải `0 errors 0 warnings`
3. Mở **Strategy Tester** (Ctrl+R) trong MT5

### Cấu hình Strategy Tester

| Setting | Giá trị đề xuất |
|---|---|
| Expert Advisor | `EMA14_Fade` |
| Symbol | `XAUUSD` (theo broker) |
| Period | `M5` |
| Date | từ 2024-04-10 đến 2026-04-10 |
| Modeling | Every tick based on real ticks |
| Deposit | `1000` USD |
| Leverage | `1:100` |

### Spread / Commission / Slippage

- **Spread:** Custom 35 (≈ spread thực XAUUSD)
- **Commission:** ~$5/lot round-trip (set qua Custom Symbol)
- **Slippage:** đã có trong EA (`InpSlippagePoints = 30`)

## Workflow phát triển chiến lược

Quy trình đã dùng cho strategy này (áp dụng cho mọi strategy mới):

1. **Visualize trước** trên TradingView bằng Pine `indicator()` — vẽ EMA, band, mũi tên entry. Lăn chart kiểm tra mắt thường.
2. **Khi mắt thấy logic đúng** → port sang MT5 EA bằng MQL5
3. **Backtest** trên Strategy Tester với spec gần thực tế (spread + commission + slippage)
4. **Phân tích kết quả** → tinh chỉnh tham số → backtest lại
5. **Forward test** trên demo account trước khi live

## Lưu ý rủi ro

- Mean-reversion strategies thường có **win rate cao + avg win < avg loss + Max DD lớn khi trend mạnh**. Đó là pattern bình thường, không phải bug.
- **TP = floating PnL cố định + lot variable** nghĩa là TP price distance KHÔNG cố định — lot càng to thì TP càng gần. Theo dõi xem có hiện tượng "TP gần quá → bị stopped out trước khi chạm" không.
- **Không có exit thời gian** — nếu giá đi ngang lâu, vị thế có thể "ngủ" rất lâu.
- **Ở vol cực thấp**, SL distance theo σ có thể rất hẹp → lot size cực to. Không có safety floor (đã bị xoá theo yêu cầu user).
- **News spike** (NFP, FOMC...) có thể gây whipsaw mạnh, cả 2 chiều LONG/SHORT đều có rủi ro stopped out liên tiếp.

## Phiên bản

- **v1.72** (hiện tại) — TP dual mode: `InpUseTP_USD` + `InpUseTP_Band` 2 bool độc lập, có thể bật cả 2 (first-hit-wins). Bỏ enum `InpTP_Mode`.
- **v1.71** — Martingale sizing: `InpSizingMode` (RISK vs MARTINGALE), `InpStartVolume`, `InpGridMult`.
- **v1.70** — **Grid entry (DCA fade)**: Level 0 market khi signal, levels 1..N-1 fill khi giá chạm (tick-based). Risk chia đều `InpRiskPercent / gridLevels`. SL chung auto-bump để bao toàn grid. Skip level nếu vượt SL. Defaults tune: devLen=100, bandLookback=4, maxBars=2, devAvgLen=100, SL=4σ, grid=5 levels @ 0.5σ. **Quan trọng**: fix bug `GetPositionPnL()` chỉ đọc 1 position → giờ cộng dồn toàn grid (TP_USD giờ mới hoạt động đúng).
- **v1.60** — **Continuous tier** (Cách C): `InpMinEntryStd` float tự nhập, confirm target = exact σ-extension thực tế. SL auto-bump dùng `MathCeil`. Pine bỏ label entry để chart gọn.
- **v1.51** — Đổi `InpEnableTier1` (bool) thành `InpMinEntryTier` (dropdown 1/2/3/4)
- **v1.50** — Sideways filter (dev ratio), toggle tier 1
- **v1.40** — SL mở rộng 2–6σ, TP mode USD hoặc BAND (0/1/2/3σ)
- **v1.30** — Tier-based confirm target (setup +Nσ cần confirm −Nσ), SL auto-bump
- **v1.22** — Dropdown chọn SL band 2σ/3σ/4σ
- **v1.21** — Bỏ floor `InpMinSL_Points`, SL thuần stdev
- **v1.20** — SL dynamic theo std3 thay vì fixed points
- **v1.10** — Thêm SHORT logic (mirror)
- **v1.00** — LONG only, SL fixed 300 points
