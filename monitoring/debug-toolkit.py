#!/usr/bin/env python3
"""
debug-toolkit.py - Interactive debugging toolkit for production systems

Usage:
    ./debug-toolkit.py [options]

Options:
    -h, --help          Show this help
    -r, --remote HOST   Run on remote host via SSH
    -n, --namespace NS  Default K8s namespace
"""

import os
import sys
import subprocess
import signal
import argparse
from datetime import datetime
from typing import Optional, List, Tuple

# Colors for terminal output
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[0;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    RESET = '\033[0m'


def colored(text: str, color: str) -> str:
    """Return colored text for terminal"""
    return f"{color}{text}{Colors.RESET}"


def print_header(title: str):
    """Print a header box"""
    width = 50
    print()
    print(colored("=" * width, Colors.CYAN))
    print(colored(title.center(width), Colors.BOLD))
    print(colored("=" * width, Colors.CYAN))
    print()


def print_section(title: str):
    """Print a section header"""
    print()
    print(colored(f"--- {title} ---", Colors.BOLD))
    print()


def run_command(cmd: str, remote_host: Optional[str] = None) -> Tuple[int, str]:
    """Run a command locally or remotely, return exit code and output"""
    if remote_host:
        cmd = f"ssh -o ConnectTimeout=10 -o BatchMode=yes {remote_host} '{cmd}'"
    
    try:
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=60
        )
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 1, "Command timed out"
    except Exception as e:
        return 1, str(e)


def run_interactive(cmd: str, remote_host: Optional[str] = None):
    """Run an interactive command"""
    if remote_host:
        cmd = f"ssh -t {remote_host} '{cmd}'"
    
    try:
        subprocess.run(cmd, shell=True)
    except KeyboardInterrupt:
        pass


class DebugToolkit:
    """Interactive debugging toolkit"""
    
    def __init__(self, remote_host: Optional[str] = None, namespace: str = "default"):
        self.remote_host = remote_host
        self.namespace = namespace
    
    def run_cmd(self, cmd: str) -> Tuple[int, str]:
        return run_command(cmd, self.remote_host)
    
    def run_interactive_cmd(self, cmd: str):
        run_interactive(cmd, self.remote_host)

    # -------------------------------------------------------------------------
    # Network Debugging
    # -------------------------------------------------------------------------
    
    def network_menu(self):
        """Network debugging menu"""
        while True:
            print_section("Network Debugging")
            print("  1) Connectivity test (ping)")
            print("  2) Port scan")
            print("  3) DNS resolution")
            print("  4) Traceroute")
            print("  5) Active connections")
            print("  6) Interface statistics")
            print("  7) TCP dump (capture)")
            print("  b) Back to main menu")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.ping_test()
            elif choice == "2":
                self.port_scan()
            elif choice == "3":
                self.dns_test()
            elif choice == "4":
                self.traceroute()
            elif choice == "5":
                self.show_connections()
            elif choice == "6":
                self.interface_stats()
            elif choice == "7":
                self.tcpdump_capture()
            elif choice.lower() == "b":
                break
    
    def ping_test(self):
        target = input("Target host/IP: ").strip()
        count = input("Ping count [5]: ").strip() or "5"
        
        code, output = self.run_cmd(f"ping -c {count} {target}")
        print(output)
    
    def port_scan(self):
        target = input("Target host: ").strip()
        ports = input("Ports (comma-separated or range, e.g., 22,80,443 or 1-1000): ").strip()
        
        # Try nc first, then nmap
        if "-" in ports:
            print("Scanning port range...")
            code, output = self.run_cmd(f"nmap -p {ports} {target} 2>/dev/null || echo 'nmap not installed'")
        else:
            for port in ports.split(","):
                port = port.strip()
                code, output = self.run_cmd(f"nc -zv -w2 {target} {port} 2>&1")
                status = colored("OPEN", Colors.GREEN) if code == 0 else colored("CLOSED", Colors.RED)
                print(f"  Port {port}: {status}")
    
    def dns_test(self):
        target = input("Hostname to resolve: ").strip()
        
        print("\nUsing system resolver:")
        code, output = self.run_cmd(f"host {target}")
        print(output)
        
        print("\nUsing dig:")
        code, output = self.run_cmd(f"dig +short {target}")
        print(output if output else "No results")
    
    def traceroute(self):
        target = input("Target host: ").strip()
        
        print("Running traceroute (this may take a moment)...")
        self.run_interactive_cmd(f"traceroute -n -m 15 {target} 2>/dev/null || tracepath {target}")
    
    def show_connections(self):
        print("\nActive connections:")
        code, output = self.run_cmd("ss -tunapl 2>/dev/null | head -50")
        print(output)
    
    def interface_stats(self):
        print("\nInterface statistics:")
        code, output = self.run_cmd("ip -s link")
        print(output)
    
    def tcpdump_capture(self):
        interface = input("Interface [any]: ").strip() or "any"
        port = input("Port filter (optional): ").strip()
        duration = input("Duration in seconds [10]: ").strip() or "10"
        
        port_filter = f"port {port}" if port else ""
        
        print(f"\nCapturing for {duration} seconds... (Ctrl+C to stop)")
        print("Note: Requires root privileges")
        
        self.run_interactive_cmd(
            f"timeout {duration} tcpdump -i {interface} {port_filter} -nn 2>/dev/null || echo 'tcpdump requires root'"
        )

    # -------------------------------------------------------------------------
    # Process Debugging
    # -------------------------------------------------------------------------
    
    def process_menu(self):
        """Process debugging menu"""
        while True:
            print_section("Process Debugging")
            print("  1) Top processes by CPU")
            print("  2) Top processes by memory")
            print("  3) Find process by name")
            print("  4) Process details (strace)")
            print("  5) Open files by process")
            print("  6) Thread analysis")
            print("  7) Zombie processes")
            print("  b) Back to main menu")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.top_by_cpu()
            elif choice == "2":
                self.top_by_memory()
            elif choice == "3":
                self.find_process()
            elif choice == "4":
                self.strace_process()
            elif choice == "5":
                self.open_files()
            elif choice == "6":
                self.thread_analysis()
            elif choice == "7":
                self.zombie_processes()
            elif choice.lower() == "b":
                break
    
    def top_by_cpu(self):
        print("\nTop 15 processes by CPU:")
        code, output = self.run_cmd("ps aux --sort=-%cpu | head -16")
        print(output)
    
    def top_by_memory(self):
        print("\nTop 15 processes by memory:")
        code, output = self.run_cmd("ps aux --sort=-%mem | head -16")
        print(output)
    
    def find_process(self):
        name = input("Process name pattern: ").strip()
        code, output = self.run_cmd(f"ps aux | grep -i '{name}' | grep -v grep")
        print(output if output else "No matching processes")
    
    def strace_process(self):
        pid = input("Process ID: ").strip()
        duration = input("Duration in seconds [5]: ").strip() or "5"
        
        print(f"\nTracing PID {pid} for {duration} seconds...")
        print("Note: Requires root privileges")
        
        self.run_interactive_cmd(f"timeout {duration} strace -p {pid} 2>&1 | head -100")
    
    def open_files(self):
        pid_or_name = input("Process ID or name: ").strip()
        
        if pid_or_name.isdigit():
            code, output = self.run_cmd(f"ls -la /proc/{pid_or_name}/fd 2>/dev/null | head -50")
        else:
            code, output = self.run_cmd(f"lsof -c {pid_or_name} 2>/dev/null | head -50")
        
        print(output if output else "No results (may require root)")
    
    def thread_analysis(self):
        pid = input("Process ID: ").strip()
        code, output = self.run_cmd(f"ps -T -p {pid}")
        print(output)
    
    def zombie_processes(self):
        code, output = self.run_cmd("ps aux | awk '$8 ~ /Z/ {print}'")
        if output:
            print("\nZombie processes found:")
            print(output)
        else:
            print(colored("\nNo zombie processes", Colors.GREEN))

    # -------------------------------------------------------------------------
    # Log Analysis
    # -------------------------------------------------------------------------
    
    def log_menu(self):
        """Log analysis menu"""
        while True:
            print_section("Log Analysis")
            print("  1) System logs (journalctl)")
            print("  2) Auth/security logs")
            print("  3) Kernel messages (dmesg)")
            print("  4) Search logs by pattern")
            print("  5) Failed services")
            print("  6) Recent errors")
            print("  b) Back to main menu")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.journalctl_menu()
            elif choice == "2":
                self.auth_logs()
            elif choice == "3":
                self.dmesg_logs()
            elif choice == "4":
                self.search_logs()
            elif choice == "5":
                self.failed_services()
            elif choice == "6":
                self.recent_errors()
            elif choice.lower() == "b":
                break
    
    def journalctl_menu(self):
        print("\n  1) Last 100 lines")
        print("  2) Since 1 hour ago")
        print("  3) Since boot")
        print("  4) Follow (live)")
        print("  5) Specific unit")
        
        choice = input("Choice: ").strip()
        
        if choice == "1":
            self.run_interactive_cmd("journalctl -n 100 --no-pager")
        elif choice == "2":
            self.run_interactive_cmd("journalctl --since '1 hour ago' --no-pager | tail -200")
        elif choice == "3":
            self.run_interactive_cmd("journalctl -b --no-pager | tail -200")
        elif choice == "4":
            self.run_interactive_cmd("journalctl -f")
        elif choice == "5":
            unit = input("Unit name: ").strip()
            self.run_interactive_cmd(f"journalctl -u {unit} -n 100 --no-pager")
    
    def auth_logs(self):
        code, output = self.run_cmd(
            "tail -100 /var/log/auth.log 2>/dev/null || tail -100 /var/log/secure 2>/dev/null"
        )
        print(output if output else "Auth log not found")
    
    def dmesg_logs(self):
        print("\n  1) All messages")
        print("  2) Errors only")
        print("  3) Hardware messages")
        
        choice = input("Choice: ").strip()
        
        if choice == "1":
            code, output = self.run_cmd("dmesg -T 2>/dev/null | tail -100")
        elif choice == "2":
            code, output = self.run_cmd("dmesg -T --level=err,crit,alert,emerg 2>/dev/null")
        elif choice == "3":
            code, output = self.run_cmd("dmesg -T 2>/dev/null | grep -iE 'disk|memory|cpu|hardware|error'")
        else:
            return
        
        print(output)
    
    def search_logs(self):
        pattern = input("Search pattern: ").strip()
        since = input("Since (e.g., '1 hour ago', '2024-01-01') [1 hour ago]: ").strip() or "1 hour ago"
        
        code, output = self.run_cmd(f"journalctl --since '{since}' --no-pager | grep -i '{pattern}' | tail -100")
        print(output if output else "No matches found")
    
    def failed_services(self):
        code, output = self.run_cmd("systemctl --failed --no-pager")
        print(output)
    
    def recent_errors(self):
        code, output = self.run_cmd(
            "journalctl -p err --since '1 hour ago' --no-pager | tail -50"
        )
        print(output if output else "No errors in the last hour")

    # -------------------------------------------------------------------------
    # Resource Analysis
    # -------------------------------------------------------------------------
    
    def resource_menu(self):
        """Resource analysis menu"""
        while True:
            print_section("Resource Analysis")
            print("  1) Real-time monitoring (top)")
            print("  2) Memory details")
            print("  3) Disk I/O (iotop)")
            print("  4) Disk usage")
            print("  5) Memory pressure")
            print("  6) CPU info")
            print("  7) I/O stats")
            print("  b) Back to main menu")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.run_interactive_cmd("top")
            elif choice == "2":
                self.memory_details()
            elif choice == "3":
                self.run_interactive_cmd("iotop -a 2>/dev/null || echo 'iotop not installed (requires root)'")
            elif choice == "4":
                self.disk_usage()
            elif choice == "5":
                self.memory_pressure()
            elif choice == "6":
                self.cpu_info()
            elif choice == "7":
                self.io_stats()
            elif choice.lower() == "b":
                break
    
    def memory_details(self):
        print("\nMemory Summary:")
        code, output = self.run_cmd("free -h")
        print(output)
        
        print("\nTop memory consumers:")
        code, output = self.run_cmd("ps aux --sort=-%mem | head -10")
        print(output)
    
    def disk_usage(self):
        print("\nFilesystem usage:")
        code, output = self.run_cmd("df -h")
        print(output)
        
        print("\nLargest directories in /:")
        code, output = self.run_cmd("du -sh /* 2>/dev/null | sort -rh | head -10")
        print(output)
    
    def memory_pressure(self):
        code, output = self.run_cmd("cat /proc/meminfo")
        
        lines = {l.split(':')[0].strip(): l.split(':')[1].strip() 
                 for l in output.split('\n') if ':' in l}
        
        print("\nMemory Pressure Analysis:")
        print(f"  MemTotal:     {lines.get('MemTotal', 'N/A')}")
        print(f"  MemFree:      {lines.get('MemFree', 'N/A')}")
        print(f"  MemAvailable: {lines.get('MemAvailable', 'N/A')}")
        print(f"  Buffers:      {lines.get('Buffers', 'N/A')}")
        print(f"  Cached:       {lines.get('Cached', 'N/A')}")
        print(f"  SwapTotal:    {lines.get('SwapTotal', 'N/A')}")
        print(f"  SwapFree:     {lines.get('SwapFree', 'N/A')}")
    
    def cpu_info(self):
        code, output = self.run_cmd("lscpu")
        print(output)
    
    def io_stats(self):
        code, output = self.run_cmd("iostat -x 1 3 2>/dev/null || echo 'iostat not installed'")
        print(output)

    # -------------------------------------------------------------------------
    # Kubernetes Debugging
    # -------------------------------------------------------------------------
    
    def k8s_menu(self):
        """Kubernetes debugging menu"""
        while True:
            print_section(f"Kubernetes Debugging (ns: {self.namespace})")
            print("  1) Pod status")
            print("  2) Get pod logs")
            print("  3) Exec into pod")
            print("  4) Describe pod")
            print("  5) Port forward")
            print("  6) Recent events")
            print("  7) Node status")
            print("  8) Change namespace")
            print("  b) Back to main menu")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.k8s_pod_status()
            elif choice == "2":
                self.k8s_logs()
            elif choice == "3":
                self.k8s_exec()
            elif choice == "4":
                self.k8s_describe()
            elif choice == "5":
                self.k8s_port_forward()
            elif choice == "6":
                self.k8s_events()
            elif choice == "7":
                self.k8s_nodes()
            elif choice == "8":
                self.change_namespace()
            elif choice.lower() == "b":
                break
    
    def k8s_pod_status(self):
        code, output = self.run_cmd(f"kubectl get pods -n {self.namespace} -o wide")
        print(output)
    
    def k8s_logs(self):
        # List pods first
        code, output = self.run_cmd(f"kubectl get pods -n {self.namespace} --no-headers")
        print("Available pods:")
        print(output)
        
        pod = input("\nPod name: ").strip()
        container = input("Container (optional): ").strip()
        
        container_flag = f"-c {container}" if container else ""
        
        print("\n  1) Last 100 lines")
        print("  2) Follow")
        print("  3) Previous container")
        
        choice = input("Choice: ").strip()
        
        if choice == "1":
            code, output = self.run_cmd(f"kubectl logs {pod} -n {self.namespace} {container_flag} --tail=100")
            print(output)
        elif choice == "2":
            self.run_interactive_cmd(f"kubectl logs {pod} -n {self.namespace} {container_flag} -f")
        elif choice == "3":
            code, output = self.run_cmd(f"kubectl logs {pod} -n {self.namespace} {container_flag} --previous --tail=100")
            print(output)
    
    def k8s_exec(self):
        pod = input("Pod name: ").strip()
        shell = input("Shell [/bin/sh]: ").strip() or "/bin/sh"
        
        self.run_interactive_cmd(f"kubectl exec -it {pod} -n {self.namespace} -- {shell}")
    
    def k8s_describe(self):
        resource = input("Resource type [pod]: ").strip() or "pod"
        name = input("Resource name: ").strip()
        
        self.run_interactive_cmd(f"kubectl describe {resource} {name} -n {self.namespace} | less")
    
    def k8s_port_forward(self):
        pod = input("Pod name: ").strip()
        ports = input("Ports (local:remote, e.g., 8080:80): ").strip()
        
        print("Port forwarding... Press Ctrl+C to stop")
        self.run_interactive_cmd(f"kubectl port-forward {pod} -n {self.namespace} {ports}")
    
    def k8s_events(self):
        code, output = self.run_cmd(
            f"kubectl get events -n {self.namespace} --sort-by='.lastTimestamp' | tail -30"
        )
        print(output)
    
    def k8s_nodes(self):
        code, output = self.run_cmd("kubectl get nodes -o wide")
        print(output)
        
        print("\nNode conditions:")
        code, output = self.run_cmd("kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[-1].type}={.status.conditions[-1].status}{\"\\n\"}{end}'")
        print(output)
    
    def change_namespace(self):
        code, output = self.run_cmd("kubectl get ns --no-headers | awk '{print $1}'")
        print("Available namespaces:")
        print(output)
        
        ns = input("\nNew namespace: ").strip()
        self.namespace = ns
        print(colored(f"Switched to namespace: {ns}", Colors.GREEN))

    # -------------------------------------------------------------------------
    # Main Menu
    # -------------------------------------------------------------------------
    
    def main_menu(self):
        """Main menu"""
        while True:
            print_header("Debug Toolkit")
            
            target = self.remote_host if self.remote_host else "localhost"
            print(f"  Target: {target}")
            print()
            
            print("  1) Network Debugging")
            print("  2) Process Debugging")
            print("  3) Log Analysis")
            print("  4) Resource Analysis")
            print("  5) Kubernetes Debugging")
            print("  q) Quit")
            print()
            
            choice = input("Enter choice: ").strip()
            
            if choice == "1":
                self.network_menu()
            elif choice == "2":
                self.process_menu()
            elif choice == "3":
                self.log_menu()
            elif choice == "4":
                self.resource_menu()
            elif choice == "5":
                self.k8s_menu()
            elif choice.lower() == "q":
                print("\nGoodbye!")
                break


def main():
    parser = argparse.ArgumentParser(description="Debug Toolkit")
    parser.add_argument("-r", "--remote", help="Remote host to debug")
    parser.add_argument("-n", "--namespace", default="default", help="Default K8s namespace")
    
    args = parser.parse_args()
    
    # Handle interrupt gracefully
    signal.signal(signal.SIGINT, lambda s, f: print("\nInterrupted"))
    
    toolkit = DebugToolkit(remote_host=args.remote, namespace=args.namespace)
    toolkit.main_menu()


if __name__ == "__main__":
    main()
