<?php
declare(strict_types=1);
namespace OCA\BaiduDriveQuota\AppInfo;

use OCA\BaiduDriveQuota\Listener\MountListener;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\Files\Events\BeforeFileSystemSetupEvent;

class Application extends App implements IBootstrap {
    public function __construct() {
        parent::__construct('baidudrive_quota');
    }
    public function register(IRegistrationContext $context): void {
        $context->registerEventListener(BeforeFileSystemSetupEvent::class, MountListener::class);
    }
    public function boot(IBootContext $context): void {
    }
}
