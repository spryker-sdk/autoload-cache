<?php

namespace SprykerSdk\AutoloadCache;

use Composer\Composer;
use Composer\EventDispatcher;
use Composer\IO\IOInterface;
use Composer\Plugin\PluginInterface;
use Composer\Script\Event;
use Composer\Script\ScriptEvents;

class ComposerPlugin implements PluginInterface, EventDispatcher\EventSubscriberInterface
{
    public const COMPOSER_DIR = 'composer';
    public const COMPOSER_POST_AUTOLOAD_DUMP_OPTIMIZE = 'optimize';
    public const COMPOSER_CONFIG_VENDOR_DIR = 'vendor-dir';

    public const ORIGINAL_SUFFIX = 'Original';

    /** @var boolean */
    protected $disabled = false;

    /**
     * @inheritDoc
     */
    public function activate(Composer $composer, IOInterface $io)
    {
        // guard for self-update problem
        if (__CLASS__ !== 'SprykerSdk\AutoloadCache\ComposerPlugin') {
            $this->disable();

            return;
        }
    }

    /**
     * @inheritDoc
     */
    public static function getSubscribedEvents()
    {
        return [
            ScriptEvents::POST_AUTOLOAD_DUMP => 'onPostAutoloadDump',
        ];
    }

    /**
     * @param \Composer\Script\Event $event
     *
     * @return void
     */
    public function onPostAutoloadDump(Event $event): void
    {
        if ($this->disabled) {
            return;
        }

        $composer = $event->getComposer();
        $config = $composer->getConfig();

        $targetDir = $config->get(static::COMPOSER_CONFIG_VENDOR_DIR) . DIRECTORY_SEPARATOR . static::COMPOSER_DIR;
        $template = __DIR__ . DIRECTORY_SEPARATOR . 'template' . DIRECTORY_SEPARATOR . 'Redis' . DIRECTORY_SEPARATOR . 'ClassLoader.php';
        $loaderFile = $targetDir . DIRECTORY_SEPARATOR . 'ClassLoader.php';
        $originalLoaderFile = $targetDir . DIRECTORY_SEPARATOR . 'ClassLoader' . static::ORIGINAL_SUFFIX . '.php';

        $classMapAuthoritative = $event->getFlags()[static::COMPOSER_POST_AUTOLOAD_DUMP_OPTIMIZE] ?? false;
        if ($classMapAuthoritative || $event->isDevMode() === false || !file_exists($template)) {
            file_exists($originalLoaderFile) && unlink($originalLoaderFile);
            return;
        }

        $originalLoaderContent = str_replace([
            'class ClassLoader',
            'private function',
            'private $',
        ], [
            'class ClassLoaderOriginal',
            'protected function',
            'protected $',
        ], file_get_contents($loaderFile));

        file_put_contents($originalLoaderFile, $originalLoaderContent);
        file_put_contents($loaderFile, file_get_contents($template));
    }

    /**
     * @return void
     */
    protected function disable(): void
    {
        $this->disabled = true;
    }
}
