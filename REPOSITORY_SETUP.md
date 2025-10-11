# Repository Setup Guide - Nimble OKE

Instructions for completing the GitHub repository setup.

## 1. Rename Repository (Manual Step)

The repository should be renamed from `nvidia-nim-oke` to `nimble-oke` for proper branding.

### Steps to Rename on GitHub:

1. **Go to Repository Settings**
   - Navigate to: https://github.com/frankbesch/nvidia-nim-oke/settings
   - Or: Repository → Settings

2. **Rename Repository**
   - Scroll to "Repository name" section
   - Change from: `nvidia-nim-oke`
   - Change to: `nimble-oke`
   - Click "Rename"

3. **Update Local Remote** (after renaming on GitHub):
   ```bash
   cd /Users/frankbesch/nvidia-nim-oke
   git remote set-url origin https://github.com/frankbesch/nimble-oke.git
   git remote -v  # Verify
   ```

4. **Optional: Rename Local Directory**
   ```bash
   cd /Users/frankbesch
   mv nvidia-nim-oke nimble-oke
   cd nimble-oke
   ```

### GitHub Automatic Redirect

After renaming, GitHub automatically redirects:
- `github.com/frankbesch/nvidia-nim-oke` → `github.com/frankbesch/nimble-oke`
- Old URLs continue to work

---

## 2. Add GitHub Topics

Add these topics to make the repository discoverable.

### How to Add Topics:

1. Go to repository main page: https://github.com/frankbesch/nimble-oke
2. Click the ⚙️ gear icon next to "About" (right sidebar)
3. In the "Topics" field, add these keywords:

### Recommended Topics (12 total):

**Primary Topics:**
- `platform-engineering`
- `smoke-testing`
- `nvidia-nim`
- `kubernetes`
- `oke`
- `oracle-cloud`

**Technology Topics:**
- `gpu`
- `helm`
- `llm`
- `ai-inference`
- `cost-optimization`
- `devops`

### Topics Format

```
platform-engineering, smoke-testing, nvidia-nim, kubernetes, oke, oracle-cloud, gpu, helm, llm, ai-inference, cost-optimization, devops
```

Just paste the comma-separated list into the Topics field.

---

## 3. Update Repository Description

### Current Description:
```
Deploy NVIDIA NIM with Meta Llama 3.1 8B on Oracle Kubernetes Engine with GPU acceleration
```

### Suggested New Description:
```
Ultra-fast, cost-efficient smoke testing platform for NVIDIA NIM on OCI OKE. Complete runbook automation with cost guards, idempotent operations, and production-grade patterns. Deploy and test GPU-accelerated AI inference for ~$12.
```

### How to Update:

1. Go to repository main page
2. Click ⚙️ gear next to "About"
3. Update description
4. Click "Save changes"

---

## 4. Add Repository Website (Optional)

If you create documentation site or want to reference the runbook:

**Options:**
- Leave empty
- Use: `https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm` (OKE docs)
- Use: `https://docs.nvidia.com/nim/` (NIM docs)

---

## 5. Verify Repository Settings

### Recommended Settings:

**General:**
- ✅ Public repository
- ✅ Include README
- ✅ Include LICENSE (MIT)
- ⬜ Issues enabled (for community feedback)
- ⬜ Discussions disabled (unless you want community)

**Features:**
- ⬜ Wikis disabled (docs are in repo)
- ⬜ Projects disabled
- ✅ Preserve this repository (mark as important)

---

## 6. Add Repository Tags

Create a release tag for the initial version:

```bash
git tag -a v1.0.0 -m "Nimble OKE v1.0.0 - Initial release

Platform engineering framework for rapid smoke testing of NVIDIA NIM on OCI OKE.

Features:
- Runbook-driven workflow
- Cost guards and tracking
- Idempotent operations
- Automatic cleanup hooks
- Enhanced Helm chart
- Comprehensive documentation
"

git push origin v1.0.0
```

---

## 7. Star Your Own Repository

Don't forget to star your repository! Shows confidence in your work.

- Go to: https://github.com/frankbesch/nimble-oke
- Click ⭐ Star (top right)

---

## Checklist

After completing all steps:

- [ ] Repository renamed to `nimble-oke`
- [ ] Local remote updated to new URL
- [ ] Topics added (12 recommended topics)
- [ ] Repository description updated
- [ ] LICENSE file visible on GitHub
- [ ] Optional: Release tag v1.0.0 created
- [ ] Optional: Repository starred

---

## Verification

Visit your repository and confirm:

1. **Main page shows:**
   - ✅ Repository name: `nimble-oke`
   - ✅ Description mentions smoke testing
   - ✅ Topics are visible
   - ✅ LICENSE badge shows "MIT"
   - ✅ README displays cleanly

2. **About section shows:**
   - ✅ Updated description
   - ✅ All topics visible

3. **Code tab shows:**
   - ✅ Clean professional presentation
   - ✅ All runbook scripts visible

---

## After Setup Complete

Your repository will be:
- ✅ Professionally named (nimble-oke)
- ✅ Easily discoverable (12 topics)
- ✅ Properly licensed (MIT)
- ✅ Clean history (1 commit, no AI refs)
- ✅ Ready to share and deploy

**Then:** Deploy to OCI and validate the platform end-to-end!

