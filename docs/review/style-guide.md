# BeaRTravel 樣式指南（最小版）

原則：不加裝飾、不加動畫、不加漸層、不加新顏色；每一條都是「移除」或「統一」。

## 1. 色彩
- **主色（唯一品牌色）**：熊毛棕 `#9A6440`（來源：`Tools/BrandArt/draw.swift` 的 fur／「BeaRTravel」字樣色）。新增 `App/Resources/Assets.xcassets/AccentColor.colorset`（light `#9A6440`、dark `#C8925F`），並在 `project.yml` BearTravel 與 ShareExtension 兩個 target 的 `settings.base` 加 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`（放在第 40 行 `ASSETCATALOG_COMPILER_APPICON_NAME` 旁）。View 一律寫 `.tint` / `Color.accentColor`，不寫 `.blue`。主色只給「可以點」的東西：Button、NavigationLink、Toggle、Picker、tab bar、選取勾號、地圖今日路線。
- **中性色**：只用系統 `.primary` / `.secondary` / `.tertiary` / `.quaternary` / `.bar` / `.regularMaterial`；LaunchBackground 的米色 `#FFF6E6` 只留在啟動畫面，不當 List 底色。
- **語意色（最多 4 個，全用系統色）**：
  | 語意 | 顏色 | 現有用法 |
  |---|---|---|
  | 固定行程 | 無顏色，`lock.fill` 用 `.secondary` | TodayView:93、TripViews:423、TripMapView:120（Pin 內白色） |
  | 衝突／錯誤 | `.red` | MatchNumbers:21「會遲到」、所有 errorMessage |
  | 不確定／需注意 | `.orange` | 無法估算 StopEditingViews:16、時區不符 TripViews:205、解析失敗 ImportFlowView:64、待確認 ImportFlowView:343、AI 無法判斷 AssistantView:47、重新確認 ProposalReviewView:46／ShareFlowView:169、司機卡警語 TaxiCardView:48 |
  | 已完成／已購買 | `.green` | ShoppingView:171 勾號、ImportFlowView:464 |
  | 次要／未定位／預設狀態 | `.secondary` | 未定位 TripViews:431／SavedView:212、未安排 ShoppingView:182、庫存未知 ShoppingView:242／TripMapView:177、離線 TodayView:144／SavedView:55 |
- **禁止**：`.yellow`、`.purple`、直接寫 `.blue` / `.gray`（地圖非今日 Pin 用 `Color(.systemGray)`）。

## 2. 文字
- 只用 `.title3`（sheet／詳情標題）、`.body`（列標題、內容、按鈕）、`.subheadline`（時間欄、副標）、`.caption`（地址、狀態、附註）。不用 `.caption2`、`.headline`、`.callout`、`.title2`。
- `.semibold` 只用於：sheet／詳情第一行標題（`.title3.weight(.semibold)`）。列標題、狀態、附註一律不加粗。
- 例外：TaxiCardView 司機區允許固定字級，但只留兩層（店名 40 heavy；請求句／地址／extras 同一級 26 regular）。
- 分隔符一律「 · 」（半形中點、前後空格）。

## 3. 卡片與列表
- 一律用 `List`／`Form` 系統群組樣式；不自畫卡片。唯一自訂容器（TaxiCardView）統一：`.padding(16)`、`RoundedRectangle(cornerRadius: 16)`、`.background(.quaternary)`；無 shadow、無邊框。
- 每列最多 3 行：標題（.body）／一行狀態（.caption .secondary，用「 · 」串接類別、狀態、人數）／一行動作（最多 1 個主要動作 + 1 個切換）。其餘動作收進點列後的 sheet。
- Badge：每列最多 1 個，且只用 SF Symbol（`lock.fill`、`bag`），不用 Capsule 膠囊、不用底色文字。
- 圖示只用 SF Symbols，不用 emoji。語意固定：AI＝`sparkles`、固定＝`lock.fill`、未定位＝`mappin.slash`、離線＝`icloud.slash`（橫幅 `wifi.slash`）、失敗／警告＝`exclamationmark.triangle`、需你決定＝`questionmark.circle`、完成＝`checkmark.circle.fill`。
- 錯誤訊息：共用 `ErrorText(message)`（`Text(message).foregroundStyle(.red)`，body 字級、無圖示、無底色），放在畫面第一個 Section。

## 4. 主要動作
- 每個畫面最多一個 `.borderedProminent`（主色填滿）按鈕；toolbar 只留一個主要圖示。其餘一律 `.borderless`（文字按鈕）或收進 `Menu("更多", systemImage: "ellipsis.circle")`。
- 破壞性動作用 `role: .destructive`，不另外上色。

## 5. 數字
- 順路：`路程 +N 分`（無法計算寫 `無法估算`，不寫數字）；行內用 `.caption .secondary`，表格用 `LabeledContent("路程", value:)`（body）。
- 路段：`約 N 分`（交通方式由圖示表達，不重複寫字）。
- 停留：`+N 分`。價格：`₩12,000`／`NT$350`（貨幣符號在前，千分位）。數量：`N 人想去`、`N 人想買`、`已買 N／M`。
- 日期：`第 N 天 · 2026-09-26`，不裸露 ISO 字串或 IANA 時區 ID（用 `TripTimeZones.displayName`）。
- 所有數字文字加 `.monospacedDigit()`。

## 第一批修改（依影響排序）
1. `project.yml:40` 旁 + `App/Resources/Assets.xcassets/` → 新增 `AccentColor.colorset`（#9A6440／#C8925F）與 `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`（BearTravel 與 ShareExtension 兩個 target）。不改任何 View。
2. `TodayView.swift:93`、`TripViews.swift:423` → `.foregroundStyle(.orange)` 改 `.secondary`，兩處都用 `.font(.caption)`。
3. `TripMapView.swift:120` → emoji 改 `Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white)`。
4. `TripMapView.swift:133-137` → `.todayRoute: .accentColor`，其餘四個 case 一律 `Color(.systemGray)`；`:35` 虛線改 `.accentColor.opacity(0.5)`。
5. `TodayView.swift:146`、`TripViews.swift:222`、`TripMapView.swift:61` → 刪除「資料版本 rN」（TripViews 整個 Section 一併刪）。
6. `SavedView.swift:206-209` → 標題去掉 `.font(.headline)`；類別移除 `.padding` 與 `.background(.quaternary, in: Capsule())`，改 `.font(.caption).foregroundStyle(.secondary)`。
7. `SavedView.swift:220-229` → 從列中移除 `TaxiCardButton` 與 `LocalMapSearchButtons`；改為點整列開詳情 sheet（比照 PinDetailView）。列只留標題、狀態、想去、一個主要動作。
8. `ShoppingView.swift:182` → `未安排` 改 `.secondary`；`:190` `.caption2` 改併入狀態行「未安排 · N 人想買」；`:171` 勾號加 `.foregroundStyle(entry.isPurchased ? .green : .secondary)`。
9. `ShoppingView.swift:242`、`TripMapView.swift:177` → 「庫存未知」文字保留，顏色改 `.secondary`。
10. `RootView.swift:52` → `.background(.yellow.opacity(0.25))` 改 `.background(.bar)`；文案縮成「離線中：顯示最近一次的資料」；`TodayView.swift:144` `.orange` 改 `.secondary`。
11. `TaxiCardView.swift:34` → 改 `.padding(16)` + `.background(.quaternary, in: RoundedRectangle(cornerRadius: 16))`（與第 54 行相同，並拿掉那裡的 `.opacity(0.5)`）；`:18-29` 縮成兩層字級。
12. `ImportFlowView.swift:464` → `.green` 保留（已完成語意）；`:340` `wand.and.stars` + `.tint` 改 `Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)`；`:442`、`:455` 「・」改「 · 」。
13. `StopEditingViews.swift:69` 與其餘 23 處 `Text(errorMessage).foregroundStyle(.red)` → 抽 `ErrorText`，移除 `.font(.caption)` 變體。
14. `TodayView.swift:113` → 改 `"路程 +N 分 · 類別"`；`TodayView.swift:90-95` 改用 `StopRow(stop:place:)` 取代手刻 HStack。
15. `TripViews.swift:246-252` → 「更多」Menu 對所有成員顯示並收進「成員」「刪除旅程」；「試算順路」改文字按鈕 `Button("試算順路")`，toolbar 只留它一個。