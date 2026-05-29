const tvSyncPayloadType = 'flclashm_tv_sync';
const legacyTvSyncPayloadTypes = {'flclashx_tv_sync'};

bool isSupportedTvSyncPayloadType(String? type) {
  if (type == null) {
    return false;
  }
  return type == tvSyncPayloadType || legacyTvSyncPayloadTypes.contains(type);
}
