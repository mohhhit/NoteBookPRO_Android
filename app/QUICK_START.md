# Quick Start Guide - Android App

## What Changed?

Your Android app now has:
- ✅ **Settings Dialog** - Configure backend URL directly from the app
- ✅ **Dynamic URL Support** - Works with localhost (PC), local IP, Ngrok, or LocalTunnel
- ✅ **Better Error Messages** - Helpful hints when connection fails
- ✅ **Persistent Settings** - Your backend URL is saved between app restarts

## Installation

1. **Install the new APK on your Android device:**
   - Transfer `build\app\outputs\flutter-apk\app-release.apk` to your phone
   - Install the APK (allow "Install from Unknown Sources" if prompted)

## Configuration Steps

### Option 1: Using Local Network IP (Recommended for same WiFi)

1. **Find your PC's IP address:**
   ```powershell
   ipconfig
   ```
   Look for "IPv4 Address" under your WiFi/Ethernet adapter (e.g., `192.168.1.100`)

2. **Start backend on your PC:**
   ```powershell
   cd F:\NoteBookPRO\backend
   virt\Scripts\activate
   uvicorn app:app --host 0.0.0.0 --port 8000
   ```
   **Important:** Use `--host 0.0.0.0` to allow connections from other devices!

3. **Configure the app:**
   - Open the app
   - Tap the **Settings** icon (⚙️) in the top-right corner
   - Enter: `http://YOUR_PC_IP:8000` (e.g., `http://192.168.1.100:8000`)
   - Click **Save**
   - The app will reload and connect!

### Option 2: Using Ngrok (Works from anywhere)

1. **Start ngrok tunnel:**
   ```powershell
   cd F:\NoteBookPRO
   ngrok http 8000
   ```
   Copy the HTTPS URL (e.g., `https://abc123.ngrok-free.app`)

2. **Configure the app:**
   - Tap Settings (⚙️)
   - Enter the ngrok URL: `https://abc123.ngrok-free.app`
   - Click Save

### Option 3: Using LocalTunnel (Alternative to Ngrok)

1. **Start LocalTunnel:**
   ```powershell
   cd F:\NoteBookPRO
   lt --port 8000 --subdomain mynotebook
   ```
   Copy the URL (e.g., `https://mynotebook.loca.lt`)

2. **Configure the app:**
   - Tap Settings (⚙️)
   - Enter the URL: `https://mynotebook.loca.lt`
   - Click Save

## Troubleshooting

### "Cannot connect to backend server"
- **Check:** Is the backend running on your PC?
- **Check:** Are you using the correct IP/URL in settings?
- **Check:** Is your phone on the same WiFi network (for local IP)?
- **Fix:** Tap Settings (⚙️) and verify the backend URL

### Connection works on PC but not phone
- Make sure backend started with `--host 0.0.0.0` (not just default localhost)
- Verify your PC's firewall allows port 8000
- Confirm phone and PC are on same WiFi network

### Backend URL changed
- Simply open Settings (⚙️) and update the URL
- The app will automatically reconnect

## Tips

- **Local IP** is fastest and most reliable when on same WiFi
- **Ngrok** is best when you need access from anywhere
- **Settings icon** is always in the top-right corner of the app
- Your backend URL is saved - no need to reconfigure every time!

## Need More Help?

See the detailed guide: [ANDROID_SETUP.md](ANDROID_SETUP.md)
