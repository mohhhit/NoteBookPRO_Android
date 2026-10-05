# NotebookPRO - Android Setup Guide

## Backend Configuration for Android

When running NotebookPRO on Android, the app cannot connect to `localhost:8000` because localhost refers to the Android device itself, not your PC.

### Option 1: Use Your PC's Local IP Address (Same WiFi Network)

1. **Find Your PC's IP Address:**
   - Windows: Open PowerShell and run `ipconfig`
   - Look for "IPv4 Address" (e.g., `192.168.1.100`)

2. **Start Backend on PC:**
   ```powershell
   cd F:\NoteBookPRO\backend
   .\virt\Scripts\python.exe -m uvicorn main:app --host 0.0.0.0 --port 8000
   ```

3. **Configure App:**
   - Open NotebookPRO app on Android
   - Tap the **Settings icon** (⚙️) in the top right
   - Enter your backend URL: `http://192.168.1.100:8000`
   - Tap **Save**

### Option 2: Use Ngrok Tunnel (Access from Anywhere)

1. **Start Ngrok Tunnel:**
   ```powershell
   cd F:\NoteBookPRO\backend
   python start_ngrok_tunnel.py
   ```
   
2. **Copy the Ngrok URL** from the terminal output (e.g., `https://abc123-xyz.ngrok-free.app`)

3. **Configure App:**
   - Open NotebookPRO app on Android
   - Tap the **Settings icon** (⚙️) in the top right  
   - Enter your ngrok URL: `https://abc123-xyz.ngrok-free.app`
   - Tap **Save**

### Option 3: Use LocalTunnel

1. **Start LocalTunnel:**
   ```powershell
   cd F:\NoteBookPRO\backend
   python start_tunnel.py
   ```

2. **Use the provided URL** in the app settings

## Troubleshooting

### "Failed to load spaces" Error

- **Check if backend is running** on your PC
- **Verify the URL** in Settings is correct
- **Ensure both devices are on the same WiFi** (for local IP option)
- **Check firewall settings** - Windows Firewall might be blocking port 8000

### Backend Not Starting

```powershell
# Navigate to backend folder
cd F:\NoteBookPRO\backend

# Activate virtual environment
.\virt\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt

# Start server
python -m uvicorn main:app --host 0.0.0.0 --port 8000
```

## Quick Start

1. **On PC:** Start backend server
2. **On Android:** Open app → Settings → Enter backend URL → Save
3. **Done!** Start chatting with your documents

## Default URLs

- **Local Development (PC/Web):** `http://localhost:8000`
- **Same WiFi (Android):** `http://YOUR_PC_IP:8000`
- **Ngrok/Tunnel:** `https://your-unique-url.ngrok-free.app`
