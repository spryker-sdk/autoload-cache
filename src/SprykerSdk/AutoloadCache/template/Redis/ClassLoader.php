<?php

namespace Composer\Autoload;

use Redis;

include __DIR__ . DIRECTORY_SEPARATOR . 'ClassLoaderOriginal.php';

class ClassLoader extends ClassLoaderOriginal
{
    protected const SEPARATOR = ':';
    protected const BULK_SIZE = 100;

    /**
     * @var bool
     */
    protected $redisCacheEnabled = false;

    /**
     * @var string
     */
    protected $redisHost = 'localhost';

    /**
     * @var int
     */
    protected $redisPort = 6379;

    /**
     * @var int
     */
    protected $redisDatabase = 0;

    /**
     * @var string
     */
    protected $redisKeyPrefix = 'autoload';

    /**
     * @var string[]
     */
    protected $redisCachedClassMap = [];

    /**
     * @var string[]
     */
    protected $redisCacheBuffer = [];

    public function __construct()
    {
        $this->redisCacheEnabled = (bool)getenv('COMPOSER_AUTOLOAD_CACHE_ENABLED');
        $this->redisHost = getenv('COMPOSER_AUTOLOAD_CACHE_REDIS_HOST') ?: $this->redisHost;
        $this->redisPort = getenv('COMPOSER_AUTOLOAD_CACHE_REDIS_PORT') ?: $this->redisPort;
        $this->redisDatabase = getenv('COMPOSER_AUTOLOAD_CACHE_REDIS_DATABASE') ?: $this->redisDatabase;

        if ($this->redisCacheEnabled) {
            $this->loadCache();
        }
    }

    public function __destruct()
    {
        $this->flushCache();
    }

    /**
     * @inheritDoc
     */
    protected function findFileWithExtension($class, $ext)
    {
        if ($this->redisCacheEnabled && isset($this->redisCachedClassMap[$class])) {
            return $this->redisCachedClassMap[$class];
        }

        $file = parent::findFileWithExtension($class, $ext);

        if ($this->redisCacheEnabled) {
            $this->putInCache($class, $file);
        }

        return $file;
    }

    /**
     * @param string $class
     * @param string|false $file
     */
    protected function putInCache(string $class, $file): void
    {
        $cacheKey = implode(static::SEPARATOR, [
            $this->redisKeyPrefix,
            $file ? realpath($file) : '',
            str_replace('\\', '/', $class)
        ]);
        $this->redisCacheBuffer[$cacheKey] = $class;

        if (count($this->redisCacheBuffer) >= static::BULK_SIZE) {
            $this->flushCache();
        }
    }

    /**
     * @return void
     */
    protected function flushCache(): void
    {
        if (count($this->redisCacheBuffer) === 0) {
            return;
        }

        if ($redis = $this->connectToRedis()) {
            $redis->mset($this->redisCacheBuffer);
            $redis->close();
        }

        $this->redisCacheBuffer = [];
    }

    /**
     * @return void
     */
    protected function loadCache(): void
    {
        if ($redis = $this->connectToRedis()) {
            $keys = $redis->keys('*');
            if (!empty($keys)) {
                $values = $redis->mget($keys);
                $this->redisCachedClassMap = $this->mapCacheDataToClassMap($keys, $values);
            }
            $redis->close();
        }
    }

    /**
     * @param array $keys
     * @param array $values
     *
     * @return array
     */
    protected function mapCacheDataToClassMap(array $keys, array $values): array
    {
        return array_map(function ($fileAndClass) {
            return explode(static::SEPARATOR, $fileAndClass)[1] ?: false;
        },
            array_flip(array_combine($keys, $values))
        );
    }

    /**
     * @return \Redis|null
     */
    protected function connectToRedis(): ?Redis
    {
        $redis = new Redis();

        if (!$redis->pconnect($this->redisHost, $this->redisPort)) {
            return null;
        }

        $redis->select($this->redisDatabase);

        return $redis;
    }
}
