#pragma once

void LatteOverlay_init();
void LatteOverlay_render(bool pad_view);
void LatteOverlay_updateStats(double fps, sint32 drawcalls, sint32 fastDrawcalls);

void LatteOverlay_pushNotification(const std::string& text, sint32 duration);

#if BOOST_OS_IOS
// WiiPad: extra distance (physical pixels) of top-anchored overlays/notifications from the top edge, so they sit
// below the on-screen toolbar instead of under it
void LatteOverlay_setTopInset(float pixels);
#endif