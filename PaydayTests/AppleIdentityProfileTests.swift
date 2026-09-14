import Foundation
import Testing
@testable import Payday

struct AppleIdentityProfileTests {
    @Test func usesTheGivenNameProvidedByApple() {
        var fullName = PersonNameComponents()
        fullName.givenName = "  Tyler  "
        fullName.familyName = "Szakacs"

        #expect(AppleIdentityProfile.newFirstName(from: fullName, currentFirstName: nil) == "Tyler")
    }

    @Test func doesNotInventANameWhenAppleDoesNotProvideOne() {
        var whitespaceOnly = PersonNameComponents()
        whitespaceOnly.givenName = "   "

        #expect(AppleIdentityProfile.newFirstName(from: nil, currentFirstName: nil) == nil)
        #expect(AppleIdentityProfile.newFirstName(from: whitespaceOnly, currentFirstName: nil) == nil)
    }

    @Test func preservesAnExistingName() {
        var fullName = PersonNameComponents()
        fullName.givenName = "Tyler"

        #expect(AppleIdentityProfile.newFirstName(from: fullName, currentFirstName: "Alex") == nil)
    }
}
