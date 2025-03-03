# script
Shellscript list for DevOps / Linux Engineer
* Cloud Disk Scaling
* TBA

# 🚀 Cloud Disk Resizer (AWS & GCP) - Automate EBS & Persistent Disk Scaling

Managing cloud resources efficiently is **critical** for cost optimization and scalability. Manually resizing disks on **AWS (EBS)** and **GCP (Persistent Disks)** can be **time-consuming** and **error-prone**.  

This script automates the process with:  
✅ **Logging** (Tracks actions in `resize_cloud_disk.log`)  
✅ **Notifications** (Alerts via `notify-send` for Linux and `osascript` for macOS)  
✅ **Dry-Run Mode** (Preview actions before execution)  
✅ **Interactive CLI** (Color-coded UI for an intuitive experience)  
✅ **Multi-Cloud Support** (Works for AWS & GCP)  

---

## 📌 Features & Functions

### 📝 Logging: Tracks Every Action
```bash
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}
```
📌 Why?
Logging ensures we track every action, making it easier to debug and review past executions.

🔔 Notifications: Sends Alerts for Status Updates
```bash
notify() {
    MESSAGE=$1
    if command -v notify-send &>/dev/null; then
        notify-send "Cloud Disk Resizer" "$MESSAGE"
    elif command -v osascript &>/dev/null; then
        osascript -e "display notification \"$MESSAGE\" with title \"Cloud Disk Resizer\""
    fi
}
```
📌 Why?
Sends real-time notifications for status updates, improving usability.

🛑 Dry-Run Mode: Prevents Accidental Execution
```bash
if [[ "$DRY_RUN" == "true" ]]; then
    log "🛑 Dry-Run: Would execute AWS resize command here."
else
    aws ec2 modify-volume --volume-id "$VOLUME_ID" --size "$NEW_SIZE" | tee -a "$LOG_FILE"
fi
```
📌 Why?
This allows users to test the script before applying changes, reducing risk.

🖥️ Interactive CLI with Choice-Based Options
```bash
read -p "👉 Enter your choice (1-6): " choice
case $choice in
    1) echo "Select Cloud Provider" ;;
    2) echo "Enter Disk ID" ;;
    3) echo "Enter New Size" ;;
    4) echo "Enable/Disable Dry-Run" ;;
    5) echo "Start Resizing Process" ;;
    6) echo "Exit" ;;
    *) echo "Invalid option" ;;
esac
```
📌 Why?
Instead of hardcoding values, users can interactively select options, improving flexibility!

📖 How to Use
1️⃣ Clone the Repository
```bash
git clone https://github.com/your-repo/cloud-disk-resizer.git
cd cloud-disk-resizer
```
2️⃣ Make the Script Executable

```bash
chmod +x resize_cloud_disk.sh
```
3️⃣ Run the Script
```bash
./resize_cloud_disk.sh
🔍 Example Executions
1️⃣ Resizing AWS EBS Volume
✅ Dry-Run Example


👉 Select Cloud Provider: AWS
👉 Enter AWS Volume ID: vol-0123456789abcdef
👉 Enter New Size (GB): 100
👉 Enable Dry-Run? (yes/no): yes

🛑 Dry-Run Mode Enabled.
🔄 Simulating resizing AWS EBS Volume vol-0123456789abcdef to 100 GB...
✅ Dry-Run: No actual changes made.
🔄 Actual Execution

👉 Select Cloud Provider: AWS
👉 Enter AWS Volume ID: vol-0123456789abcdef
👉 Enter New Size (GB): 100
👉 Enable Dry-Run? (yes/no): no

🔄 Resizing AWS EBS Volume vol-0123456789abcdef to 100 GB...
✅ Resize operation completed.
2️⃣ Resizing GCP Persistent Disk
✅ Dry-Run Example

👉 Select Cloud Provider: GCP
👉 Enter GCP Disk Name: my-disk
👉 Enter New Size (GB): 200
👉 Enter GCP Zone: us-central1-a
👉 Enable Dry-Run? (yes/no): yes

🛑 Dry-Run Mode Enabled.
🔄 Simulating resizing GCP Persistent Disk my-disk to 200 GB in us-central1-a...
✅ Dry-Run: No actual changes made.
🔄 Actual Execution

👉 Select Cloud Provider: GCP
👉 Enter GCP Disk Name: my-disk
👉 Enter New Size (GB): 200
👉 Enter GCP Zone: us-central1-a
👉 Enable Dry-Run? (yes/no): no

🔄 Resizing GCP Persistent Disk my-disk to 200 GB in us-central1-a...
✅ Resize operation completed.
```
🔥 Why This Matters for DevOps Engineers
	•	Saves time by automating AWS & GCP disk resizing.
	•	Prevents errors with logging, notifications, and dry-run mode.
	•	Improves efficiency with a user-friendly interface.

🚀 Try it out & contribute to the project!
Got ideas for improvements? Open a Pull Request!

📢 Connect & Share

If you found this useful, feel free to share and connect with me on LinkedIn!
💬 Let’s discuss: #DevOps #CloudComputing #AWS #GCP #Automation #BashScripting
