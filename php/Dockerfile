# syntax=docker/dockerfile:1
# System: Suno Automation Gateway
# Module: PHP Proxy Container
# File URL: php/Dockerfile
# Purpose: Build a PHP Apache container that proxies chat requests to the FastAPI backend.

FROM php:8.2-apache

ENV APACHE_DOCUMENT_ROOT=/var/www/html/public

RUN sed -ri "s!/var/www/html!${APACHE_DOCUMENT_ROOT}!g" /etc/apache2/sites-available/000-default.conf \
    && sed -ri "s!/var/www/!${APACHE_DOCUMENT_ROOT}/!g" /etc/apache2/apache2.conf

COPY public/ /var/www/html/public/
COPY src/ /var/www/html/src/

RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

CMD ["apache2-foreground"]
