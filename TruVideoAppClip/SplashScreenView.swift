//
//  SplashScreenView.swift
//  TruVideo
//
//  Created by Sanchai Ahilan J K  on 10/07/25.
//


import SwiftUI

struct SplashScreenView: View {
    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            Image("truvideo_logo")
                .resizable()
                .scaledToFit()
                .frame(width: 200, height: 200)
        }
    }
}
