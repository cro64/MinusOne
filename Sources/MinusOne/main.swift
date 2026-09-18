import AppKit

if CommandLine.arguments.contains("--list-devices") {
    for device in CoreAudioDevices.allDevices() {
        print("\(device.id)\t\(device.name)\tinput=\(device.inputChannelCount)\toutput=\(device.outputChannelCount)\tuid=\(device.uid)")
    }
    exit(EXIT_SUCCESS)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
