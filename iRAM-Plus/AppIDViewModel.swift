//
//  AppIDViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import Foundation
import StosSign_API
import StosSign_Auth
import StosSign_Common

class AppIDModel : ObservableObject, Hashable {
    static func == (lhs: AppIDModel, rhs: AppIDModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    var appID: AppID
    @Published var bundleID: String
    @Published var name: String
    @Published var result: String = ""
    
    init(appID: AppID) {
        self.appID = appID
        bundleID = appID.bundleIdentifier
        name = appID.name
    }
    
    func addIncreasedMemory() async throws {
        guard let team = DataManager.shared.model.team, let session = DataManager.shared.model.session else {
            throw "Please Login First"
        }

        let enableIncreasedMemoryLimit = UserDefaults.standard.bool(forKey: "enableIncreasedMemoryLimit")
        let enableExtendedVirtualAddressing = UserDefaults.standard.bool(forKey: "enableExtendedVirtualAddressing")
        
        var capabilities: [String] = []
        
        if enableIncreasedMemoryLimit {
            capabilities.append("INCREASED_MEMORY_LIMIT")
        }
        
        if enableExtendedVirtualAddressing {
            capabilities.append("EXTENDED_VIRTUAL_ADDRESSING")
        }
        
        let cool = try await AppleAPI.shared.updateAppID(appID, capabilities: capabilities, team: team, session: session)
        
        await MainActor.run {
            var successMessage = "✅ Success! "
            var enabledCapabilities: [String] = []
            
            if enableIncreasedMemoryLimit {
                enabledCapabilities.append("Increased Memory Limit")
            }
            if enableExtendedVirtualAddressing {
                enabledCapabilities.append("Extended Virtual Addressing")
            }
            
            if enabledCapabilities.count == 1 {
                successMessage += "\(enabledCapabilities[0]) capability has been enabled."
            } else {
                successMessage += "\(enabledCapabilities.joined(separator: " and ")) capabilities have been enabled."
            }
            
            let enableDebugging = UserDefaults.standard.bool(forKey: "enableDebugging")
            if enableDebugging {
                successMessage += "\n\nAPI Response:\n\(cool)"
            }
            result = successMessage
        }
    }
    
}

class AppIDViewModel : ObservableObject {
    @Published var appIDs : [AppIDModel] = []
    
    func fetchAppIDs() async throws {
        guard let team = DataManager.shared.model.team, let session = DataManager.shared.model.session else {
            throw "Please Login First"
        }
        
        let ids = try await AppleAPI.shared.fetchAppIDsForTeam(team: team, session: session)
        await MainActor.run {
            appIDs.removeAll()
            for id in ids {
                appIDs.append(AppIDModel(appID: id))
            }
        }
    }
}
