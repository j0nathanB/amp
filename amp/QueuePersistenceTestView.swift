//
//  QueuePersistenceTestView.swift
//  amp
//
//  Test view for verifying queue persistence functionality
//

#if DEBUG
import SwiftUI

struct QueuePersistenceTestView: View {
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @State private var debugInfo = ""
    @State private var testResult = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Queue Persistence Test")
                .font(.largeTitle)
                .padding()
            
            Group {
                Text("Current Queue Info")
                    .font(.headline)
                
                HStack {
                    Text("Tracks in queue:")
                    Text("\(audioPlayer.playbackQueue.count)")
                        .foregroundColor(.blue)
                }
                
                HStack {
                    Text("Current index:")
                    Text("\(audioPlayer.currentIndex)")
                        .foregroundColor(.blue)
                }
                
                if let track = audioPlayer.currentTrack {
                    Text("Current: \(track.title)")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            
            Text("Storage Info")
                .font(.headline)
            
            ScrollView {
                Text(debugInfo)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .frame(maxHeight: 200)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            
            VStack(spacing: 10) {
                Button(action: {
                    testResult = "Force saving queue..."
                    audioPlayer.debugForceSaveQueue()
                    updateDebugInfo()
                    testResult = "Queue saved successfully!"
                }) {
                    Text("Force Save Queue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button(action: {
                    Task {
                        testResult = "Force loading queue..."
                        await audioPlayer.debugForceLoadQueue()
                        updateDebugInfo()
                        testResult = "Queue loaded! Tracks: \(audioPlayer.playbackQueue.count)"
                    }
                }) {
                    Text("Force Load Queue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button(action: {
                    Task {
                        testResult = "Clearing all storage..."
                        await audioPlayer.debugClearAllStorage()
                        updateDebugInfo()
                        testResult = "All storage cleared!"
                    }
                }) {
                    Text("Clear All Storage")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .padding()
            
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding()
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            updateDebugInfo()
        }
    }
    
    private func updateDebugInfo() {
        debugInfo = audioPlayer.debugPersistenceInfo()
    }
}

struct QueuePersistenceTestView_Previews: PreviewProvider {
    static var previews: some View {
        QueuePersistenceTestView()
    }
}
#endif