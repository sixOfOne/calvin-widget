import SwiftUI
import WidgetKit

struct StripEntry: TimelineEntry {
    let date: Date
    let pageURL: URL
    let stripDay: Date
    let imageData: Data?
    let message: String?

    static func placeholder(date: Date = Date()) -> StripEntry {
        StripEntry(
            date: date,
            pageURL: StripStore.homeURL,
            stripDay: Calendar.current.startOfDay(for: date),
            imageData: nil,
            message: nil
        )
    }

    static func waiting(date: Date = Date()) -> StripEntry {
        StripEntry(
            date: date,
            pageURL: StripStore.pageURL(for: date),
            stripDay: Calendar.current.startOfDay(for: date),
            imageData: nil,
            message: "Open the Calvin and Hobbes app."
        )
    }
}

struct StripProvider: TimelineProvider {
    func placeholder(in context: Context) -> StripEntry {
        StripEntry.placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (StripEntry) -> Void) {
        completion(makeEntry(isPreview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StripEntry>) -> Void) {
        let entry = makeEntry(isPreview: false)
        completion(Timeline(entries: [entry], policy: .after(refreshDate(for: entry))))
    }

    private func makeEntry(isPreview: Bool) -> StripEntry {
        let now = Date()
        if isPreview {
            return StripEntry.placeholder(date: now)
        }
        if let cached = StripStore.load() {
            return StripEntry(
                date: now,
                pageURL: cached.pageURL,
                stripDay: cached.day,
                imageData: cached.imageData,
                message: nil
            )
        }
        return StripEntry.waiting(date: now)
    }

    /// Today's saved strip waits until 12:20am. Anything else checks again soon, in case the app has written a new file.
    private func refreshDate(for entry: StripEntry) -> Date {
        let now = entry.date
        let calendar = Calendar.current
        let isToday = calendar.isDate(entry.stripDay, inSameDayAs: now)
        if entry.imageData != nil && isToday {
            let start = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(24 * 60 * 60)
            return calendar.date(byAdding: .minute, value: 20, to: tomorrow) ?? tomorrow
        }
        return now.addingTimeInterval(30 * 60)
    }
}

struct CalvinWidgetEntryView: View {
    var entry: StripEntry

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .containerBackground(StripStyle.paper, for: .widget)
            .widgetURL(entry.pageURL)
    }

    @ViewBuilder
    private var content: some View {
        if let data = entry.imageData, StripImage.cgImage(from: data) != nil {
            StripImageView(data: data)
                .padding(10)
        } else {
            status(
                title: "Calvin and Hobbes",
                message: entry.message ?? "Today's strip"
            )
        }
    }

    private func status(title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(.headline, design: .serif))
                .foregroundStyle(StripStyle.ink)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(StripStyle.ink.opacity(0.68))
        }
        .padding(12)
    }
}

struct CalvinAndHobbesWidget: Widget {
    let kind = "CalvinAndHobbes"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StripProvider()) { entry in
            CalvinWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Calvin and Hobbes")
        .description("Today's strip from GoComics.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}

@main
struct CalvinWidgetBundle: WidgetBundle {
    var body: some Widget {
        CalvinAndHobbesWidget()
    }
}

#Preview(as: .systemMedium) {
    CalvinAndHobbesWidget()
} timeline: {
    StripEntry.placeholder()
    StripEntry.waiting()
}

#Preview(as: .systemLarge) {
    CalvinAndHobbesWidget()
} timeline: {
    StripEntry.waiting()
}
