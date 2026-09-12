//
//  AppIDViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import Foundation
import StosSign_API_NoCertificate
import StosSign_Auth

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

        logging(text: "Refreshing Anisette data if needed...")
        try await AppleAPI.shared.refreshAnisetteDataIfNeeded(for: session)
        logging(text: "Anisette data refresh completed")

        let enableIncreasedMemoryLimit = UserDefaults.standard.bool(forKey: "enableIncreasedMemoryLimit")
        let enableExtendedVirtualAddressing = UserDefaults.standard.bool(forKey: "enableExtendedVirtualAddressing")

        logging(text: "Capabilities to enable:")
        logging(text: "- Increased Memory Limit: \(enableIncreasedMemoryLimit)")
        logging(text: "- Extended Virtual Addressing: \(enableExtendedVirtualAddressing)")
        
        let dateFormatter = ISO8601DateFormatter()
        let httpHeaders = [
            "Content-Type": "application/vnd.api+json",
            "User-Agent": "akd/1.0 CFNetwork/1333.0.4",
            "Accept": "application/vnd.api+json",
            "Accept-Language": "en-us",
            "X-Apple-App-Info": "com.apple.gs.akd.auth",
            "X-Apple-I-Identity-Id": session.dsid,
            "X-Apple-GS-Token": session.authToken,
            "X-Apple-I-MD-M": session.anisetteData.machineID,
            "X-Apple-I-MD": session.anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": session.anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": session.anisetteData.routingInfo.description,
            "X-Mme-Device-Id": session.anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": session.anisetteData.deviceDescription,
            "X-Apple-I-Client-Time": dateFormatter.string(from:session.anisetteData.date),
            "X-Apple-Locale": session.anisetteData.locale.identifier,
            "X-Apple-I-TimeZone": session.anisetteData.timeZone.abbreviation()!
        ] as [String : String];
        
        logging(text: "HTTP Headers prepared (excluding sensitive tokens)")
        logging(text: "Request URL: https://developerservices2.apple.com/services/v1/bundleIds/\(appID.identifier)")
        
        // Build capabilities array based on settings
        var capabilities: [[String: Any]] = []
        
        if enableIncreasedMemoryLimit {
            capabilities.append([
                "relationships": [
                    "capability": [
                        "data": [
                            "id": "INCREASED_MEMORY_LIMIT",
                            "type": "capabilities"
                        ]
                    ]
                ],
                "type": "bundleIdCapabilities",
                "attributes": [
                    "settings": [],
                    "enabled": true
                ]
            ])
        }
        
        if enableExtendedVirtualAddressing {
            capabilities.append([
                "relationships": [
                    "capability": [
                        "data": [
                            "id": "EXTENDED_VIRTUAL_ADDRESSING",
                            "type": "capabilities"
                        ]
                    ]
                ],
                "type": "bundleIdCapabilities",
                "attributes": [
                    "settings": [],
                    "enabled": true
                ]
            ])
        }
        
        let requestBody: [String: Any] = [
            "data": [
                "relationships": [
                    "bundleIdCapabilities": [
                        "data": capabilities
                    ]
                ],
                "id": appID.identifier,
                "attributes": [
                    "hasExclusiveManagedCapabilities": false,
                    "teamId": team.identifier,
                    "bundleType": "bundle",
                    "identifier": appID.bundleIdentifier,
                    "seedId": team.identifier,
                    "name": appID.name
                ],
                "type": "bundleIds"
            ]
        ]
        
        logging(text: "Request body prepared with \(capabilities.count) capabilities")

        var request = URLRequest(url: URL(string: "https://developerservices2.apple.com/services/v1/bundleIds/\(appID.identifier)")!)
        request.httpMethod = "PATCH"
        request.allHTTPHeaderFields = httpHeaders
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        logging(text: "Sending PATCH request to Apple Developer API...")
        let (data, response) = try await URLSession.shared.data(for: request)
        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response."

        logging(text: "Response received")
        if let httpResponse = response as? HTTPURLResponse {
            logging(text: "HTTP Status: \(httpResponse.statusCode)")
        }

        let enableDebugging = UserDefaults.standard.bool(forKey: "enableDebugging")
        if enableDebugging {
            logging(text: "Response body: \(responseString)")
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            let errorMessage = "Apple API request failed with HTTP \(httpResponse.statusCode)."
            logging(text: "ERROR: \(errorMessage)")
            if enableDebugging {
                throw "\(errorMessage)\n\(responseString)"
            } else {
                throw errorMessage
            }
        }

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
            
            if enableDebugging {
                successMessage += "\n\nAPI Response:\n\(responseString)"
            }
            result = successMessage
        }
        
        logging(text: "=== Memory Limit Enablement Completed Successfully ===")
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
