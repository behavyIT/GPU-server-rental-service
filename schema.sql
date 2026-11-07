-- Сервис аренды GPU-серверов для обучения нейросетей
-- Физическая схема (PostgreSQL 14+)

CREATE EXTENSION IF NOT EXISTS btree_gist;  -- нужно для EXCLUDE (server_id WITH =, period WITH &&)

CREATE TABLE users (
    user_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE CHECK (email LIKE '%_@_%._%'),
    full_name   VARCHAR(150) NOT NULL,
    phone       VARCHAR(20)  UNIQUE,
    balance     NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE providers (
    provider_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           VARCHAR(150) NOT NULL UNIQUE,
    inn            VARCHAR(12)  NOT NULL UNIQUE CHECK (inn ~ '^[0-9]{10}([0-9]{2})?$'),
    contact_email  VARCHAR(255) NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE data_centers (
    dc_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider_id  BIGINT       NOT NULL REFERENCES providers(provider_id) ON DELETE RESTRICT,
    name         VARCHAR(100) NOT NULL,
    country      CHAR(2)      NOT NULL CHECK (country ~ '^[A-Z]{2}$'),
    city         VARCHAR(100) NOT NULL,
    address      VARCHAR(255) NOT NULL,
    tier         SMALLINT     NOT NULL CHECK (tier BETWEEN 1 AND 4),
    UNIQUE (provider_id, name)
);

CREATE TABLE servers (
    server_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dc_id        BIGINT       NOT NULL REFERENCES data_centers(dc_id) ON DELETE RESTRICT,
    hostname     VARCHAR(100) NOT NULL UNIQUE,
    cpu_model    VARCHAR(100) NOT NULL,
    cpu_cores    SMALLINT     NOT NULL CHECK (cpu_cores > 0),
    ram_gb       INTEGER      NOT NULL CHECK (ram_gb > 0),
    storage_tb   NUMERIC(6,2) NOT NULL CHECK (storage_tb > 0),
    status       VARCHAR(20)  NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'maintenance', 'retired'))
);

CREATE TABLE gpu_models (
    gpu_model_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor        VARCHAR(50)  NOT NULL,
    name          VARCHAR(100) NOT NULL,
    vram_gb       SMALLINT     NOT NULL CHECK (vram_gb > 0),
    fp16_tflops   NUMERIC(7,1) NOT NULL CHECK (fp16_tflops > 0),
    UNIQUE (vendor, name)
);

CREATE TABLE gpus (
    gpu_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    server_id      BIGINT      NOT NULL REFERENCES servers(server_id) ON DELETE CASCADE,
    gpu_model_id   BIGINT      NOT NULL REFERENCES gpu_models(gpu_model_id) ON DELETE RESTRICT,
    serial_number  VARCHAR(50) NOT NULL UNIQUE,
    slot_no        SMALLINT    NOT NULL CHECK (slot_no >= 0),
    UNIQUE (server_id, slot_no)
);

CREATE TABLE tariffs (
    tariff_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(50)  NOT NULL UNIQUE,
    billing_unit  VARCHAR(10)  NOT NULL CHECK (billing_unit IN ('hour', 'day', 'month')),
    min_units     INTEGER      NOT NULL DEFAULT 1 CHECK (min_units > 0),
    discount_pct  NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_pct BETWEEN 0 AND 100),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE
);

-- Дополнительная таблица: Сервер N:M Тариф (цена своя для каждой пары)
CREATE TABLE server_tariffs (
    server_id       BIGINT        NOT NULL REFERENCES servers(server_id) ON DELETE CASCADE,
    tariff_id       BIGINT        NOT NULL REFERENCES tariffs(tariff_id) ON DELETE RESTRICT,
    price_per_unit  NUMERIC(10,2) NOT NULL CHECK (price_per_unit > 0),
    PRIMARY KEY (server_id, tariff_id)
);

CREATE TABLE software_images (
    image_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    version       VARCHAR(30)  NOT NULL,
    framework     VARCHAR(20)  NOT NULL CHECK (framework IN ('pytorch', 'tensorflow', 'jax', 'other')),
    cuda_version  VARCHAR(10),
    UNIQUE (name, version)
);

-- Дополнительная таблица: Сервер N:M Образ ПО (какие образы установлены)
CREATE TABLE server_images (
    server_id     BIGINT      NOT NULL REFERENCES servers(server_id) ON DELETE CASCADE,
    image_id      BIGINT      NOT NULL REFERENCES software_images(image_id) ON DELETE CASCADE,
    installed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, image_id)
);

CREATE TABLE bookings (
    booking_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id      BIGINT        NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    server_id    BIGINT        NOT NULL,
    tariff_id    BIGINT        NOT NULL,
    period       TSTZRANGE     NOT NULL CHECK (NOT isempty(period) AND lower(period) IS NOT NULL AND upper(period) IS NOT NULL),
    status       VARCHAR(20)   NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'confirmed', 'active', 'completed', 'cancelled')),
    total_price  NUMERIC(12,2) NOT NULL CHECK (total_price >= 0),
    created_at   TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- бронировать можно только по тарифу, который доступен на этом сервере
    FOREIGN KEY (server_id, tariff_id) REFERENCES server_tariffs(server_id, tariff_id) ON DELETE RESTRICT,
    -- один сервер нельзя забронировать на пересекающиеся интервалы
    CONSTRAINT bookings_no_overlap EXCLUDE USING gist (server_id WITH =, period WITH &&)
        WHERE (status <> 'cancelled')
);

CREATE TABLE training_jobs (
    job_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id   BIGINT       NOT NULL REFERENCES bookings(booking_id) ON DELETE CASCADE,
    image_id     BIGINT       NOT NULL REFERENCES software_images(image_id) ON DELETE RESTRICT,
    name         VARCHAR(100) NOT NULL,
    params       JSONB        NOT NULL DEFAULT '{}'::jsonb,
    status       VARCHAR(20)  NOT NULL DEFAULT 'queued'
                 CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    CHECK (finished_at IS NULL OR (started_at IS NOT NULL AND finished_at >= started_at))
);

CREATE TABLE payments (
    payment_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id  BIGINT        NOT NULL UNIQUE REFERENCES bookings(booking_id) ON DELETE RESTRICT,
    amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    method      VARCHAR(10)   NOT NULL CHECK (method IN ('card', 'sbp', 'balance')),
    status      VARCHAR(10)   NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'paid', 'refunded', 'failed')),
    paid_at     TIMESTAMPTZ,
    CHECK (status <> 'paid' OR paid_at IS NOT NULL)
);

CREATE TABLE reviews (
    review_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id     BIGINT      NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    server_id   BIGINT      NOT NULL REFERENCES servers(server_id) ON DELETE CASCADE,
    rating      SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment     TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, server_id)
);
