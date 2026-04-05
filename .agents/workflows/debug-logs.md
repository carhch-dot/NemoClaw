---
description: How to capture and verify the deep diagnostics logs for NemoClaw
---

If you are still seeing `Permission denied` errors after redeploying with the latest `nemoclaw-start.sh`, follow these steps:

1. **Check Dokploy Logs**: View the logs for your NemoClaw service in the Dokploy dashboard.
2. **Look for `--- DEEP DIAGNOSTICS START ---`**: This block contains critical information about the environment.
3. **Capture the entire block**: Please copy and paste everything between `START` and `END` in our chat.
4. **Specific items to check**:
   - `UID`: Should be `0`.
   - `MOUNT`: Check if it says `ro` (read-only).
   - `LSATTR`: Check if there are letters like `i` (immutable) or `a` (append-only).
   - `ERROR: ... is a FILE`: This would indicate a corrupted volume mapping.

Once you provide these logs, I can pinpoint the exact system-level restriction causing the failure.
