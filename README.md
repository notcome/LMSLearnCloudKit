# LMSLearnCloudKit

An app using CRDT and CloudKit.

- There is a single list in this app. Users can edit it across devices.
- Users can add an item to or delete one from the list.
- New items can be inserted at the beginning of the app or after any given item.
- Items will show their creation time.
- Items would be in different color for different devices, but items from the local device is always in pink.
- It should support remote push notification.


## Notes

### Rough Algorithm

- Two singleton objects are used to coordinate CloudKit and the user interface: `StorageLayer` and `ListModel`.
- `StorageLayer` holds a weave in a `CurrentValueSubject`.
- Both `ListModel` and `StorageLayer` could write to the weave. The former for locally created edits, and the latter for downloaded remote edits.
- When the weave changes, `ListModel` recomputes its current list and update the SwiftUI accordingly.
- `StorageLayer` keeps track of the last local edit uploaded. When the weave changes, it uploads new edits made by this device to CloudKit.
- `StorageLayer` also keeps a list of pending edits not yet weaved into the weave. It tries to weave those edits after each successful synchronization.
- Local edits can also be in the pending edit list. But those edits are already contained in the weave, so they are skipped entirely.

### Misc.

- Apps running on a simulator cannot receive push notifications.
- We did not handle any CloudKit error. Rather, we `fatalError` whenever one happens. This helps debugging but do not use this in production code!
- We once encountered an error from `NSURLSession`. Turns out the Wi-Fi had some issue. Curiously, the error was not an `CKError`.

## References

- [The CRDT blog post, highly recommended](http://archagon.net/blog/2018/03/24/data-laced-with-history/).
- [The chronofold paper](https://arxiv.org/abs/2002.09511) written by [Victor Grischenko](https://github.com/gritzko). Not used, but I like it so much.
