import Foundation
import Supabase

enum PaydaySupabase {
    static let client: SupabaseClient = {
        guard
            let rawURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: rawURL),
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
            !key.isEmpty
        else {
            fatalError("Payday's Supabase configuration is missing")
        }

        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()
}

