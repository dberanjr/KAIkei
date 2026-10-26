import Foundation

/// Which open sessions the list shows. Archiving is a display preference only: it never touches the session itself, and
/// an archived session's spend still counts in the period totals.
public enum SessionVisibility {
    public static func partition<T>(_ items: [T], id: (T) -> String, archived: Set<String>) -> (visible: [T], archived: [T]) {
        (items.filter { !archived.contains(id($0)) }, items.filter { archived.contains(id($0)) })
    }

    /// The rows to draw: everything when archived ones are being shown, otherwise only the rest.
    public static func ordered<T>(_ items: [T], id: (T) -> String, archived: Set<String>, includeArchived: Bool) -> [T] {
        includeArchived ? items : partition(items, id: id, archived: archived).visible
    }
}
