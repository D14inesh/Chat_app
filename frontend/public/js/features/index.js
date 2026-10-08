// One import point for app.js. Each feature lives in its own module here.

export { bindFeatures, prefs } from './core.js';
export { pollBody, pollPreview, wirePolls, onPollVotes, openPollComposer, onPollClosed } from './polls.js';
export { pinButtonHtml, wirePinButtons, renderPinnedBar, onMessagePinned, isPinned } from './pins.js';
export {
  expiryMark, renderDisappearingChip, disappearingNoteHtml, openDisappearingPicker,
  onDisappearingChanged, pruneExpired, startExpiryWatcher,
} from './disappearing.js';
export { pickViewOnce, viewOnceBody, viewOncePreview, wireViewOnce, onViewOnceOpened } from './viewonce.js';
export { getDraft, setDraft, clearDraft, draftPreviewHtml } from './drafts.js';
export { openExportChat } from './export.js';
export {
  openSummarize, translateButtonHtml, translationHtml, wireTranslations, smartReplyChips,
} from './ai-tools.js';
export { onLoginAlert, openSecurityPanel } from './security.js';
export {
  loadQuickReplies, onComposerInput as quickReplyInput, onComposerKeydown as quickReplyKeydown,
  hidePopup as hideQuickReplies, openQuickRepliesPanel,
} from './quickreplies.js';
export { openBroadcastsPanel } from './broadcasts.js';
export { businessSectionHtml, wireBusinessSection, businessBlockFor } from './business.js';
export { maybePlayEffect } from './effects.js';
export { openFeatureSettings } from './settings.js';
export { openBackupPanel, startBackupWatcher, forgetBackupHere } from './backup.js';
export {
  startTicTacToe, applyTicTacToeMove, startSnakes, applySnakesMove,
} from './games2.js';

import { onPollVotes } from './polls.js';
import { onMessagePinned } from './pins.js';
import { onDisappearingChanged } from './disappearing.js';
import { onViewOnceOpened } from './viewonce.js';
import { onLoginAlert } from './security.js';
import { onLoginApproval } from './approval.js';
import { onGroupFrame } from './groups.js';
import { onPollClosed } from './polls.js';
import { onCallLog } from './calls.js';

/** Live frames for the newer features. Returns true when handled. */
export function handleFeatureFrame(frame) {
  switch (frame.type) {
    case 'poll-votes': onPollVotes(frame); return true;
    case 'message-pinned': onMessagePinned(frame); return true;
    case 'disappearing-changed': onDisappearingChanged(frame); return true;
    case 'view-once-opened': onViewOnceOpened(frame); return true;
    case 'login-alert': onLoginAlert(frame); return true;
    case 'login-approval': onLoginApproval(frame); return true;
    case 'poll-closed': onPollClosed(frame); return true;
    case 'call-log': onCallLog(frame); return true;
    default: return onGroupFrame(frame);
  }
}
export { contactFieldsHtml, wireContactFields, openContactPanel, ensureContact } from './contact.js';
export { openRecoveryKeySetup, nudgeRecoveryKey, openForgotPassword } from './recovery.js';
export {
  openGroupInfo, renderComposerLock, onChatOpened, iAmGroupAdmin, addMembersWithKey,
  mentionsEveryone, highlightEveryone, onComposerMention,
  splitPrivateReply, textOf, privateQuoteHtml, privateReplyButtonHtml, replyPrivately, packPrivateReply,
  checkInviteHash, openJoinWithLink, openJoinPreview, openCommunities,
} from './groups.js';
export {
  toggleVoice, cycleSpeed, stopVoice, repaintVoice, voiceSpeedLabel,
  openEditHistory,
  hideLocked, lockedRowHtml, wireLockedRow, canOpenChat, toggleChatLock, openChatLockSettings, unlockLockedChats,
  myStickersHtml, wireMyStickers, openStickerMaker,
  searchFilter, passesSearchFilter, searchFiltersHtml,
} from './chat3.js';
export {
  openCallsPanel, refreshMissedCalls, RINGTONES, ringtoneFor, ringtoneOverride, startRinging, stopRinging,
  openRingtonePicker, toggleGroupScreenShare, stopGroupScreenShare, applyGroupScreenShare,
} from './calls.js';
export {
  productBody, productPreview, autoBody, openCatalogue, openSendProduct, openCatalogManager,
  openAwaySettings, openChatNotes, priceText,
} from './shop.js';
export {
  birthFieldHtml, privateChatGate, setPrivateLock, archiveFilter, archivedRowHtml, wireArchivedRow, toggleArchive, viewingArchived,
} from './privacy.js';
export { waitForApproval } from './approval.js';
export { initPanels, openSettings } from './panels.js';
