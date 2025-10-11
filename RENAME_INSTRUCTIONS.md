# Repository Rename Instructions - nvidia-nim-oke → nimble-oke

## ✅ GitHub Automatic Redirect

**Good news:** When you rename a repository on GitHub, automatic redirects are created!

**After renaming:**
- Old URL: https://github.com/frankbesch/nvidia-nim-oke
- New URL: https://github.com/frankbesch/nimble-oke
- **Redirect:** Old URL automatically forwards to new URL ✓

This means:
- All existing links continue to work
- Git clones from old URL still work
- Forks and references are preserved
- No broken links anywhere

## Step-by-Step Rename Process

### Step 1: Rename on GitHub (2 minutes)

**Instructions:**

1. **Open repository settings**
   - Go to: https://github.com/frankbesch/nvidia-nim-oke
   - Click: **Settings** tab (top navigation)
   - Or directly: https://github.com/frankbesch/nvidia-nim-oke/settings

2. **Find Repository Name section**
   - Scroll down to "Repository name" (near top of General settings)
   - Current value: `nvidia-nim-oke`

3. **Rename the repository**
   - Change to: `nimble-oke`
   - Click: **Rename** button
   - GitHub will show a warning about redirects - this is normal
   - Confirm the rename

4. **GitHub creates automatic redirect**
   - https://github.com/frankbesch/nvidia-nim-oke → https://github.com/frankbesch/nimble-oke
   - Redirect is permanent and automatic

### Step 2: Update Local Git Remote (1 minute)

**After renaming on GitHub, run these commands:**

```bash
cd /Users/frankbesch/nvidia-nim-oke

# Update remote URL
git remote set-url origin https://github.com/frankbesch/nimble-oke.git

# Verify new remote
git remote -v

# Expected output:
# origin  https://github.com/frankbesch/nimble-oke.git (fetch)
# origin  https://github.com/frankbesch/nimble-oke.git (push)
```

### Step 3: Rename Local Directory (optional)

```bash
cd /Users/frankbesch

# Rename local directory to match
mv nvidia-nim-oke nimble-oke

# Enter new directory
cd nimble-oke

# Verify everything works
make help
git status
```

### Step 4: Verify Redirect Works (1 minute)

**Test the redirect:**

```bash
# Clone from old URL (should work)
git clone https://github.com/frankbesch/nvidia-nim-oke.git test-redirect

# Expected: Successfully clones from redirected URL
# GitHub will show: "Redirecting to https://github.com/frankbesch/nimble-oke.git"

# Cleanup test
rm -rf test-redirect
```

**Or test in browser:**
- Open: https://github.com/frankbesch/nvidia-nim-oke
- Should automatically redirect to: https://github.com/frankbesch/nimble-oke
- URL in address bar changes automatically

---

## ✅ Verification Checklist

After renaming, verify these:

### GitHub Web Interface

- [ ] Repository name shows `nimble-oke`
- [ ] URL is https://github.com/frankbesch/nimble-oke
- [ ] Old URL https://github.com/frankbesch/nvidia-nim-oke redirects to new URL
- [ ] LICENSE badge displays correctly
- [ ] All files visible and accessible

### Local Git Configuration

- [ ] Remote URL updated: `git remote -v` shows nimble-oke
- [ ] Can push: `git push origin main` works
- [ ] Can pull: `git pull origin main` works

### Redirect Testing

- [ ] Old URL in browser redirects to new URL
- [ ] `git clone` from old URL works with redirect message
- [ ] README note about nimble-oke is accurate

---

## 🔄 GitHub Redirect Behavior

### What GitHub Does Automatically

When you rename from `nvidia-nim-oke` to `nimble-oke`:

1. **Creates HTTP 301 redirect**
   - Permanent redirect from old to new
   - Works for all pages (not just main page)

2. **Updates all internal references**
   - Forks point to new name
   - Stars carry over
   - Issues/PRs redirect

3. **Preserves git operations**
   - `git clone https://github.com/frankbesch/nvidia-nim-oke.git` works
   - `git push` to old URL works
   - `git pull` from old URL works

4. **Maintains backward compatibility**
   - Old links in documentation work
   - Bookmarks continue to work
   - No broken references

### What You Need to Update

**Only need to update:**
- Your local git remote (one command)
- Your local directory name (optional)

**GitHub handles everything else automatically!**

---

## 🚨 Important Notes

### Redirect Limitations

GitHub's redirect works **unless:**
- Someone creates a new repository with the old name `nvidia-nim-oke`
- (Unlikely since it's your account and you're renaming)

### Best Practice

After renaming, update:
- Personal documentation/notes with new URL
- LinkedIn/portfolio links (but old links still work)
- Bookmarks (but old bookmarks redirect)

**But:** Old links continue to work via redirect, so no urgency

---

## 📝 Quick Command Reference

```bash
# After renaming on GitHub:

# Update local remote
git remote set-url origin https://github.com/frankbesch/nimble-oke.git

# Verify
git remote -v

# Optional: Rename local directory
cd /Users/frankbesch
mv nvidia-nim-oke nimble-oke
cd nimble-oke

# Test
make help
git status
git pull origin main
```

---

## ✅ Success Criteria

Repository successfully renamed when:

✓ GitHub URL is https://github.com/frankbesch/nimble-oke  
✓ Old URL redirects automatically  
✓ Local git remote updated  
✓ `make help` still works  
✓ Can push/pull normally  

---

## 🎯 Ready to Rename?

**Go to:** https://github.com/frankbesch/nvidia-nim-oke/settings

**Change:** `nvidia-nim-oke` → `nimble-oke`

**Then run:**
```bash
git remote set-url origin https://github.com/frankbesch/nimble-oke.git
```

**Redirect will work automatically!** ✨

