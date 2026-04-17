# EMA14 Mean-Reversion Fade Strategy

Fade strategy trên XAUUSD M5 dựa vào mean reversion về EMA14 sau các đợt giá nhô xa khỏi trung bình.

## Cấu trúc repo

- **[mql5/](mql5/)** — Expert Advisor cho MetaTrader 5
- **[pine/](pine/)** — Pine Script indicators cho TradingView (port từ MQL5 để visualize)

## Logic cốt lõi

- **Tier-based setup**: sau khi giá nhô high/low ≥ `minEntryStd` σ so với EMA, arm setup.
- **Confirm entry**: giá quay về chạm cùng σ-extension ở phía đối diện EMA → fire entry.
- **Grid DCA**: L0 market + L1..N limit pendings ở các level `i × spacing × σ` dưới/trên entry.
- **SL**: chung cho toàn grid, tại band `N·σ`, tự bump nếu vướng grid levels.
- **TP**: USD floating PnL hoặc giá chạm EMA ± N·σ (chọn 1 hoặc cả 2).

## Filters

- **Vol Z-Score**: block entry khi ATR ngắn vọt lên `mean + N·stdev` (detect news/shock regime).
- **Full-bar filter**: yêu cầu có ít nhất 1 bar đầy hoàn toàn phía bên kia EMA trước khi cross.
- **Min entry σ**: setup chỉ arm khi extension ≥ ngưỡng.

## File chính

### MQL5 (MetaTrader 5 EA)
- [EMA14_Fade.mq5](mql5/EMA14_Fade.mq5) — EA chính, v1.94
- [EMA14_Fade.md](mql5/EMA14_Fade.md) — documentation chi tiết
- [EMA14_Fade_Settings.md](mql5/EMA14_Fade_Settings.md) — settings guide
- [TVAgentFeed.mq5](mql5/TVAgentFeed.mq5) — TradingView signal feed helper

### Pine Script (TradingView)
- [ema14_fade.pine](pine/ema14_fade.pine) — baseline với sideways filter cũ
- [ema14_fade_volz.pine](pine/ema14_fade_volz.pine) — version hiện tại với Vol-Z filter
- [vol_zscore_filter.pine](pine/vol_zscore_filter.pine) — companion indicator visualize Vol-Z
- [ema_cross.pine](pine/ema_cross.pine) — experiment cross detection

## Cài đặt MQL5

1. Copy [EMA14_Fade.mq5](mql5/EMA14_Fade.mq5) vào `MQL5/Experts/` của MetaTrader 5.
2. Copy [TVAgentFeed.mq5](mql5/TVAgentFeed.mq5) (optional, nếu dùng TradingView → MT5 webhook).
3. Compile trong MetaEditor (F7).
4. Attach vào chart XAUUSD M5, bật AutoTrading.

Chi tiết settings xem [EMA14_Fade_Settings.md](mql5/EMA14_Fade_Settings.md).

## Cài đặt Pine

1. TradingView → Pine Editor → paste nội dung file `.pine`.
2. Save → Add to chart.
3. Khuyến nghị: dùng [ema14_fade_volz.pine](pine/ema14_fade_volz.pine) (main indicator) + [vol_zscore_filter.pine](pine/vol_zscore_filter.pine) (sub-pane) cùng lúc.

## Market & Timeframe

- **Symbol**: XAUUSD (có thể adapt sang FX, Index với re-tune).
- **Timeframe**: M5 (mean-reversion horizon).
- **Account**: $1000 base, 2% risk per setup (split across grid levels).
