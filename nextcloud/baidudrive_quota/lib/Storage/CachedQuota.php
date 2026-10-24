<?php
declare(strict_types=1);
namespace OCA\BaiduDriveQuota\Storage;

use OC\Files\Storage\Wrapper\Wrapper;
use OCP\ICache;

class CachedQuota extends Wrapper {
    private bool $loaded = false;
    private int|float|false $space = false;

    public function __construct(array $parameters, private ICache $quotaCache) {
        parent::__construct($parameters);
    }

    public function free_space(string $path): int|float|false {
        if ($this->loaded) {
            return $this->space;
        }
        $cached = $this->quotaCache->get('account_space_v1');
        if ($cached !== null) {
            $this->space = $cached;
        } else {
            // The configured Baidu account shares capacity across its folders.
            // Keep per-directory stat, list, content and write methods intact.
            $this->space = $this->getWrapperStorage()->free_space($path);
            $this->quotaCache->set('account_space_v1', $this->space, 60);
        }
        $this->loaded = true;
        return $this->space;
    }
}
