import AudioToolbox
import Foundation

enum RemoteBell {
    // The single short sound is shared by all windows for the life of the app.
    static let sound: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "RemoteBell", withExtension: "wav") else { return nil }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return nil }
        return sound
    }()

    static func play() {
        if let sound { AudioServicesPlaySystemSound(sound) }
    }
}
