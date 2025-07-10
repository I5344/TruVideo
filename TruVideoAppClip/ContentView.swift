//
//  ContentView.swift
//  TruVideoAppClip
//
//  Created by Sanchai Ahilan J K  on 08/07/25.
//

import SwiftUI

struct ContentView: View {
    @State private var showSplash = true

    var body: some View {
        Group {
            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
            } else {
                CameraView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Automatically dismiss splash screen after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    showSplash = false
                }
            }
        }
    }
}
