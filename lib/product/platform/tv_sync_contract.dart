const tvSyncPayloadType = 'flclashm_tv_sync';

bool isSupportedTvSyncPayloadType(String? type) {
  if (type == null) {
    return false;
  }
  return type == tvSyncPayloadType;
}
