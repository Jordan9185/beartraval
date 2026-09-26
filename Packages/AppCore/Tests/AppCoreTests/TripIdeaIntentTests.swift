import AppCore
import Testing

struct TripIdeaIntentTests {
    @Test func tokyoFiveDayIdea() {
        let text = "我要去 日本東京五天旅遊"
        #expect(TripIdeaIntent.isRequest(text))
        #expect(TripIdeaIntent.dayCount(in: text) == 5)
        #expect(TripIdeaIntent.suggestedName(for: text) == "東京 5 天")
        #expect(TripIdeaIntent.suggestedTimeZone(for: text) == "Asia/Tokyo")
        #expect(TripIdeaIntent.shouldSuggest("想去淺草寺、上野、迪士尼", tripDays: 5))
        #expect(!TripIdeaIntent.shouldSuggest("週一淺草寺、週二上野", tripDays: 5))
    }

    @Test func pastedScheduleStaysAnImport() {
        #expect(!TripIdeaIntent.isRequest("東京五天行程\nDay 1：淺草寺\nDay 2：上野"))
        #expect(TripIdeaIntent.inferredDayCount(in: "東京行程\nDay 1：淺草寺\nDay 5：上野") == 5)
        #expect(TripIdeaIntent.inferredDayCount(in: "東京行程\n第一天：淺草寺\n第三天：上野") == 3)
        #expect(TripIdeaIntent.inferredDayCount(in: "東京五天，想去淺草寺、上野") == 5)
        #expect(!TripIdeaIntent.isRequest("東京第一天：淺草寺"))
        #expect(!TripIdeaIntent.isRequest("10/2 14:00 淺草寺"))
        #expect(TripIdeaIntent.dayCount(in: "首爾十五天") == nil)
    }
}
