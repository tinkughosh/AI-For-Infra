# 🌐 FinBridge Azure Network Operations — AI-Augmented Workflow

> **Network Reliability Engineering** | Azure East US | Engineer: **tinkuxd** | 2026-06-19

[![IaC](https://img.shields.io/badge/IaC-Terraform%20azurerm%20~3.0-623CE4?style=flat-square&logo=terraform)](#️-infrastructure-as-code)
[![Fault Injection](https://img.shields.io/badge/Fault%20Injection-NSG%20Misconfiguration-orange?style=flat-square)](#-fault-injection--recovery)
[![Evidence](https://img.shields.io/badge/Evidence-Monitor%20Log%20%2B%20Screenshots-blue?style=flat-square)](#-incident-evidence)
[![RCA](https://img.shields.io/badge/RCA-Completed-green?style=flat-square)](#-root-cause-analysis)

---

## 📋 What This Is

This repository documents an end-to-end **AI-assisted network operations workflow** for the FinBridge Azure environment. It covers infrastructure provisioning, controlled fault simulation, real-time detection, AI-assisted diagnosis, and a full Root Cause Analysis — exactly the workflow an on-call ops team would follow for a production NSG incident.

| Area | Detail |
|------|--------|
| 🌐 **Fault type** | NSG priority conflict — Deny rule silently shadows an Allow rule |
| 🎯 **Impact** | East-west ICMP blocked between app and backend subnets |
| 🛡️ **Unaffected** | SSH management access throughout the incident |
| 🤖 **AI role** | Proposes, drafts, and interprets — engineer validates and executes every step |

---

## 🗺️ Project Milestones

```
  Provision ──────── Arm ──────── Incident Simulation ──────── Diagnose & Close
  (IaC)         (Scripts)            (Evidence)                    (RCA)
     ✅               ✅                  ✅                            ✅
```

| Milestone | Objective | Outcome |
|-----------|-----------|---------|
| 🏗️ **Provision** | Terraform IaC reviewed through 4 quality gates before deploy | All 4 gates passed |
| 🔧 **Arm** | Paired fault + restore scripts — restore proven before fault runs | Restore tested & verified |
| 💥 **Simulate** | Fault triggered, automated monitor detects impact in real time | 2 min 13 sec outage captured |
| 🔍 **Diagnose & Close** | AI triage → root cause confirmed → remediation → RCA delivered | Full handover pack produced |

---

## 🔄 Workflow

### 🏗️ Provision the Infrastructure

**1️⃣ AI generates the Terraform code**

> Prompt given to AI:
> *"Write Terraform for Azure: resource group, VNet with two subnets (app 10.10.1.0/24 and backend 10.10.2.0/24), two NSGs, two Linux VMs with public IPs and password authentication. Region eastus."*

AI produced `main.tf`, `variables.tf`, `outputs.tf`. Engineer reviewed and adjusted: added static private IPs, changed VM size to `Standard_B1ms`.

**2️⃣ Code run through four gates before deploy**

```
terraform fmt && terraform validate   → Gate 1: LINT   ✅
terraform plan                        → Gate 2: DRY-RUN ✅
terraform apply → terraform plan      → Gate 3: IDEMPOTENCY ✅
Plan output reviewed for scope        → Gate 4: BOUNDED SCOPE ✅
```

**3️⃣ Infrastructure deployed**

```
terraform apply
```

Output confirmed:
```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:
  vm_app_public_ip     = "x.x.x.x"
  vm_backend_public_ip = "x.x.x.x"
  vm_app_ssh           = "ssh labadmin@x.x.x.x"
```

Both VMs accessible via SSH. NSG baseline:

```
Priority  Name               Access  Protocol
--------  -----------------  ------  --------
100       AllowSSH           Allow   Tcp
200       AllowAppToBackend  Allow   Icmp
4096      DenyAllInbound     Deny    *
```

---

### 🔧 Arm — Fault Injection & Recovery Scripts

**Restore script written and tested FIRST — this is the graded gate.**

**1️⃣ AI designs the restore script**

> Prompt:
> *"You are a senior infrastructure on-call engineer. Write a PowerShell script that restores nsg-backend to clean state. It should: check if LabBlock8080 exists and delete it, reset AllowAppToBackend to priority 200 source 10.10.1.0/24. Use az CLI. Resource group rg-capstone-tinkuxd."*

Script saved as `Capstone/scripts/restore.ps1`. Engineer fixed: removed PowerShell backtick syntax, wrapped az query strings in variables.

**2️⃣ Restore script tested on live NSG (POC gate)**

```powershell
powershell -ExecutionPolicy Bypass -File .\restore.ps1
```

Actual output:
```
=============================================
 RESTORE SCRIPT - NSG Connectivity Fix
 Resource Group : rg-capstone-tinkuxd
 Started        : 2026-06-19 10:55:27
=============================================

[1/3] Checking for deny rule 'LabBlock8080'...
      Not found - nothing to delete.

[2/3] Restoring 'AllowAppToBackend' source to 10.10.1.0/24 at priority 200...
Allow  *  *  Inbound  AllowAppToBackend  200  Icmp  Succeeded

[3/3] Current NSG rules on nsg-backend:
Priority  Name               Access  Protocol
--------  -----------------  ------  --------
100       AllowSSH           Allow   Tcp
200       AllowAppToBackend  Allow   Icmp
4096      DenyAllInbound     Deny    *

=============================================
 RESTORE COMPLETE - 10:55:53
=============================================
```
✅ **Restore verified working before any fault was injected.**

**3️⃣ Fault injection script created**

> Prompt:
> *"Write a PowerShell fault injection script for nsg-backend. Add a countdown with Ctrl+C abort, update AllowAppToBackend to priority 300, then add a Deny ICMP rule LabBlock8080 at priority 150 (source 10.10.1.0/24). Show final NSG state."*

Engineer adjusted: priority changed 100→150 after discovering AllowSSH already occupied priority 100 (Azure returned `SecurityRuleConflict` on first attempt).

---

### 💥 Incident Simulation — Break & Detect

**1️⃣ Monitor script set up on vm-app**

SSH into vm-app, start continuous ICMP probe to vm-backend every 5 seconds:

```bash
nohup bash /opt/lab/monitor.sh > /opt/lab/evidence/monitor.log 2>&1 &
```

Monitor running from `10:41:38` — showing steady `[PASS]`.

**2️⃣ Fault injected from PowerShell**

```powershell
powershell -ExecutionPolicy Bypass -File .\fault-inject.ps1
```

Two changes made to `nsg-backend`:
- `AllowAppToBackend` moved from priority 200 → 300
- `LabBlock8080` Deny ICMP created at priority **150**

NSG state after fault:
```
Priority  Name               Access  Protocol
--------  -----------------  ------  --------
100       AllowSSH           Allow   Tcp
150       LabBlock8080       Deny    Icmp    ← fault rule
300       AllowAppToBackend  Allow   Icmp    ← now shadowed
4096      DenyAllInbound     Deny    *
```

**3️⃣ Impact captured in monitor log**

```
11:03:11  [PASS]  ICMP reachable      ← last clean probe
11:03:16  [FAIL]  ICMP UNREACHABLE    ← fault visible (3 sec after inject)
11:03:23  [FAIL]  ICMP UNREACHABLE
11:03:30  [FAIL]  ICMP UNREACHABLE
...  (27 consecutive FAIL probes)  ...
11:05:29  [FAIL]  ICMP UNREACHABLE    ← last failed probe
11:05:36  [PASS]  ICMP reachable      ← recovery confirmed
```

**Outage window: 11:03:16 → 11:05:29 | Duration: 2 min 13 sec**  
**SSH (TCP 22) was unaffected throughout.**

---

### 🔍 Diagnose & Resolve

**1️⃣ AI triage prompt run against evidence**

> Prompt:
> *"You are a senior infrastructure on-call engineer. Analyse ALL the evidence below and answer: 1. FIRST EVENT 2. ROOT CAUSE 3. EVIDENCE CHAIN 4. BLAST RADIUS 5. IMMEDIATE ACTION 6. 5-WHY 7. TIMELINE. Constraints: only use evidence provided, every statement must cite a specific evidence item, flag contradictions. --- EVIDENCE --- [monitor.log extract + NSG rule table]"*

AI correctly identified:
- Root cause: `LabBlock8080` Deny Icmp at priority 150 shadows `AllowAppToBackend` at priority 300
- Blast radius: ICMP only, SSH unaffected
- Immediate action: `az network nsg rule delete --name LabBlock8080`

**2️⃣ Safest Fix Rubric applied before executing**

| Option | Restores Service | Confidence |
|--------|-----------------|------------|
| A: Restart VMs | ❌ No — VMs don't control NSG rules | 0% |
| B: Delete LabBlock8080 | ✅ Yes — removes root cause | 99% |
| C: Change AllowAppToBackend priority to 50 | ⚠️ Partial — creates new conflict risk | 60% |

**Option B selected.**

**3️⃣ Remediation executed**

```powershell
powershell -ExecutionPolicy Bypass -File .\restore.ps1
```

**4️⃣ Recovery confirmed**

```
11:05:29  [FAIL]  ICMP UNREACHABLE    ← last failed probe
11:05:36  [PASS]  ICMP reachable      ← RECOVERY CONFIRMED
11:05:41  [PASS]  ICMP reachable
11:05:46  [PASS]  ICMP reachable
```

Recovery time: **< 7 seconds** after restore script completed.

---

## 📁 Repository Structure

```
AI-For-Infra/
├── 📄 README.md                              ← This file
├── 🚫 .gitignore                             ← Excludes credentials and state files
│
└── Capstone/
    ├── 🏗️  terraform/
    │   ├── main.tf                           ← Full Azure IaC (RG, VNet, NSGs, VMs)
    │   ├── variables.tf                      ← Input variables
    │   ├── outputs.tf                        ← Public IPs, SSH commands
    │   ├── terraform.tfvars                  ← Variable values (no secrets)
    │   └── cloud-init-backend.yaml           ← VM cloud-init config
    │
    ├── 🔧  scripts/
    │   ├── restore.ps1                       ← Restore script — tested BEFORE fault injection
    │   ├── fault-inject.ps1                  ← Fault injection script
    │   ├── monitor.log                       ← Incident evidence: PASS → FAIL → PASS timeline
    │   └── script-notes.txt                  ← Restore verification output (proof of testing)
    │
    ├── 🖼️  evidence/
    │   ├── fault-inject-evidence.PNG         ← Screenshot: fault state (ICMP blocked)
    │   └── restore-evidence.PNG              ← Screenshot: post-restore (ICMP recovered)
    │
    ├── 📊  gate-notes.txt                    ← IaC quality gates: Lint, Dry-Run, Idempotency, Scope
    ├── 📋  evidence-log.txt                  ← Timestamped incident observations (8 entries)
    ├── 💬  prompt-library.txt                ← All AI prompts used — with keep/change/reject notes
    └── 📄  rca.txt                           ← Root Cause Analysis — full handover document
```

---

## 📄 Root Cause Analysis

| Field | Detail |
|-------|--------|
| **Incident date** | 2026-06-19 |
| **Duration** | 2 minutes 13 seconds |
| **Protocol affected** | ICMP (ping) — east-west app→backend |
| **Unaffected** | SSH (TCP 22) — management access throughout |
| **Root cause** | NSG rule `LabBlock8080` (Deny / Icmp / priority **150**) inserted between `AllowSSH` (100) and `AllowAppToBackend` (300), silently shadowing the allow rule |
| **Why it blocked** | Azure NSG evaluates rules lowest-number-first and stops at first match — Deny at 150 matched before Allow at 300 was reached |
| **Fix applied** | Deleted `LabBlock8080`, reset `AllowAppToBackend` to priority 200 |
| **Recovery time** | < 7 seconds after `restore.ps1` executed |
| **Data loss** | None |

### 🔎 5-Why

```
Why was ICMP blocked?
  → LabBlock8080 Deny Icmp matched at priority 150 before AllowAppToBackend at 300
Why was a Deny rule at priority 150 allowed to exist?
  → No NSG priority band policy — any priority could be used
Why was there no priority band policy?
  → NSG rules were not managed exclusively through Terraform IaC
Why were manual az CLI changes permitted?
  → No change-control process enforcing IaC-only NSG modifications
Why was there no automated detection before impact?
  → No Azure Monitor alert configured on NSG rule create/update events
```

### 🛡️ Preventive Recommendations

| Action | Priority |
|--------|----------|
| 🔒 All NSG changes via Terraform + PR review only (no manual `az` in production) | **Immediate** |
| 📏 Define priority band policy: 100–199 mgmt / 200–499 app allow / 500+ deny | **Immediate** |
| 🔔 Azure Monitor alert on `Microsoft.Network/networkSecurityGroups/securityRules/write` | **This sprint** |
| 📊 Enable NSG Flow Logs on nsg-backend — alert on ICMP deny > 10/min | **This sprint** |

---

## 🤖 AI Role in This Project

The AI co-engineer was used at every phase — but the human engineer **validated, adjusted, and decided** at each step. Nothing was executed unattended.

| Phase | AI Contribution | Human Decision |
|-------|----------------|----------------|
| Build | Generated full Terraform structure | Added static IPs, changed VM size, switched auth method |
| Arm | Designed restore + fault scripts | Fixed PowerShell syntax, corrected priority conflict |
| Break & Detect | Designed monitor script | Changed log path, confirmed evidence manually |
| Diagnose | Ran triage, 5-Why, fix rubric, PIR | Rejected generic outputs, grounded all claims in actual log evidence |

---

*FinBridge Network Operations · AI-Augmented Workflow · tinkuxd · 2026-06-19*
