//
//  NSUserActivity.swift
//  Runner
//
//  Created by Hien Nguyen on 20/02/2022.
//

import Foundation
import Intents

// Since iOS 13 a call started from Recents / Siri / Contacts arrives as a
// single INStartCallIntent (audio or video told apart by callCapability).
// The old INStartAudioCallIntent / INStartVideoCallIntent pair is deprecated
// and is no longer what the system sends, so matching only those made
// `handle` nil for every real call-back.
extension NSUserActivity: StartCallConvertible {

    public var handle: String? {
        guard
          let interaction = interaction,
          let startCallIntent = interaction.intent as? INStartCallIntent,
          let contact = startCallIntent.contacts?.first
        else {
            return nil
        }
        print(interaction.intent)
        return contact.personHandle?.value
    }

    public var isVideo: Bool? {
        guard
          let interaction = interaction,
          let startCallIntent = interaction.intent as? INStartCallIntent
        else {
            return nil
        }

        return startCallIntent.callCapability == .videoCall
    }

}


protocol StartCallConvertible {
    var handle: String? { get }
    var isVideo: Bool? { get }
}

extension StartCallConvertible {

    var isVideo: Bool? {
        return nil
    }

}
