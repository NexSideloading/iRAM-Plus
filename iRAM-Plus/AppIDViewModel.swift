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
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.result += "\(text)\n"
            }
        }
        
        logging(text: "=== Starting Memory Limit Enablement ===")

        guard let team = DataManager.shared.model.team, let session = DataManager.shared.model.session else {
            logging(text: "ERROR: No team or session found. Please login first.")
            throw "Please Login First"
        }

        logging(text: "Team: \(String(team.identifier.prefix(8)) + "...") (\(team.identifier))")
        logging(text: "Session: dsid=\(session.dsid)")
        logging(text: "AppID: \(appID.name) (\(appID.bundleIdentifier))")

        let enableIncreasedMemoryLimit = UserDefaults.standard.bool(forKey: "enableIncreasedMemoryLimit")
        let enableExtendedVirtualAddressing = UserDefaults.standard.bool(forKey: "enableExtendedVirtualAddressing")

        logging(text: "Capabilities to enable:")
        logging(text: "- Increased Memory Limit: \(enableIncreasedMemoryLimit)")
        logging(text: "- Extended Virtual Addressing: \(enableExtendedVirtualAddressing)")
        
        var capabilities: [String] = []
        
        if enableIncreasedMemoryLimit {
            capabilities.append("INCREASED_MEMORY_LIMIT")
        }
        
        if enableExtendedVirtualAddressing {
            capabilities.append("EXTENDED_VIRTUAL_ADDRESSING")
        }
        
        logging(text: "Calling AppleAPI.shared.updateAppID with \(capabilities.count) capabilities")
        
        do {
            let cool = try await AppleAPI.shared.updateAppID(appID, capabilities: capabilities, team: team, session: session)
            
            logging(text: "Request successful!")
            
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
            
            logging(text: "=== Memory Limit Enablement Completed Successfully ===")
        } catch {
            logging(text: "ERROR: \(error.localizedDescription)")
            logging(text: "=== Memory Limit Enablement Failed ===")
            throw error
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
