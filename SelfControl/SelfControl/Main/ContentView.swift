//
//  ContentView.swift
//  SelfControl
//
//  Created by Egzon Arifi on 02/04/2025.
//

import SwiftUI
import NetworkExtension
import SystemExtensions
import os.log
import Cocoa

struct ContentView: View {
  @StateObject private var viewModel = FilterViewModel()
  
  var body: some View {
    VStack(spacing: 20) {
      // Status indicator with image and text.
      statusView
      // Show a progress indicator when in the indeterminate state.
      if viewModel.status == .indeterminate {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle())
      }
      
      // Start/Stop buttons.
      HStack {
        if viewModel.status == .stopped {
          Button("Start") {
            viewModel.startFilter()
          }
        }
        if viewModel.status == .running {
          Button("Stop") {
            viewModel.stopFilter()
          }
        }
      }
    }
    .padding()
    .frame(minWidth: 150, minHeight: 150)
  }
}

private extension ContentView {
  var statusView: some View {
    HStack {
      viewModel.status.color
        .clipShape(Circle())
        .frame(width: 20, height: 20)
      Text("Status: \(viewModel.status.text)")
    }
  }
}

#Preview {
  ContentView()
}
