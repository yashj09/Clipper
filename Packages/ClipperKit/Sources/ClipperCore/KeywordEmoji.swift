/// One emoji per common creator-vocabulary concept, keyed by lowercased lemma. The only copy: analysis attaches these
/// to `KeywordTags`, and anything that wants an emoji for a word looks it up here.
public enum KeywordEmoji {
    public static let table: [String: String] = [
        "money": "💰", "cash": "💵", "dollar": "💵", "price": "🏷️", "sale": "🏷️", "cost": "💸",
        "profit": "📈", "growth": "📈", "business": "💼", "job": "💼", "office": "🏢", "deal": "🤝",
        "time": "⏰", "clock": "⏰", "hour": "⏰", "minute": "⏱️", "day": "📅", "week": "📅", "year": "📅",
        "calendar": "📅", "camera": "📷", "photo": "📸", "picture": "🖼️", "video": "🎥", "film": "🎬", "movie": "🎬",
        "phone": "📱", "iphone": "📱", "mac": "💻", "laptop": "💻", "computer": "💻", "keyboard": "⌨️",
        "code": "💻", "internet": "🌐", "website": "🌐", "email": "📧", "message": "💬", "data": "📊", "chart": "📊",
        "idea": "💡", "brain": "🧠", "fire": "🔥", "rocket": "🚀", "launch": "🚀", "heart": "❤️", "love": "❤️",
        "warning": "⚠️", "danger": "⚠️", "problem": "⚠️", "mistake": "❌", "error": "❌", "success": "✅",
        "winner": "🏆", "trophy": "🏆", "goal": "🎯", "target": "🎯", "music": "🎵", "song": "🎵",
        "microphone": "🎙️", "podcast": "🎙️", "game": "🎮", "book": "📚", "school": "🏫", "food": "🍔",
        "coffee": "☕", "water": "💧", "car": "🚗", "plane": "✈️", "travel": "✈️", "home": "🏠", "house": "🏠",
        "world": "🌍", "earth": "🌍", "sun": "☀️", "star": "⭐", "key": "🔑", "lock": "🔒", "secret": "🤫",
        "question": "❓", "gift": "🎁", "party": "🎉", "birthday": "🎂", "dog": "🐶", "cat": "🐱", "baby": "👶",
        "family": "👪", "friend": "🤝", "team": "🤝", "health": "🩺", "doctor": "🩺", "gym": "🏋️",
        "workout": "💪", "power": "⚡", "energy": "⚡", "battery": "🔋", "tool": "🛠️", "list": "📝", "note": "📝",
        "plan": "🗺️", "map": "🗺️", "news": "📰", "light": "💡",
    ]
}
