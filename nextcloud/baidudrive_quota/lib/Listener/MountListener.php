<?php
declare(strict_types=1);
namespace OCA\BaiduDriveQuota\Listener;

use OCA\BaiduDriveQuota\Storage\CachedQuota;
use OCP\EventDispatcher\Event;
use OCP\EventDispatcher\IEventListener;
use OCP\Files\Events\BeforeFileSystemSetupEvent;
use OCP\ICacheFactory;
use OCP\IConfig;

class MountListener implements IEventListener {
    public function __construct(private ICacheFactory $cacheFactory, private IConfig $config) {
    }
    public function handle(Event $event): void {
        if (!$event instanceof BeforeFileSystemSetupEvent) {
            return;
        }
        $id = $this->config->getSystemValue('baidudrive_quota_storage_id', '');
        if ($id === '') { return; }
        $cache = $this->cacheFactory->createLocal('baidudrive_quota_' . md5($id));
        \OC\Files\Filesystem::addStorageWrapper('baidudrive_quota',
            static function ($mountPoint, $storage) use ($cache, $id) {
                if ($storage->getId() !== $id) {
                    return $storage;
                }
                return new CachedQuota(['storage' => $storage], $cache);
            }, 100);
    }
}
