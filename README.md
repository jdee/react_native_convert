# react_native_util gem

[![Gem](https://img.shields.io/gem/v/react_native_util.svg?style=flat)](https://rubygems.org/gems/react_native_util)
[![Downloads](https://img.shields.io/gem/dt/react_native_util.svg?style=flat)](https://rubygems.org/gems/react_native_util)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat)](https://github.com/jdee/react_native_util/blob/master/LICENSE)
[![CircleCI](https://img.shields.io/circleci/project/github/jdee/react_native_util.svg)](https://circleci.com/gh/jdee/react_native_util)

**Work in progress**

Community utility CLI for React Native projects.

## Prerequisites

_macOS required_

```bash
brew install yarn # Not necessary if installing from Homebrew tap
npm install -g react-native-cli
```

## Installation

```bash
[sudo] gem install react_native_util
```

## Install from Homebrew tap

```bash
brew install jdee/tap/react_native_util
```

## Gemfile

```Ruby
gem 'react_native_util'
```

## Usage

```bash
react_native_util -h
rn -h
rn react_pod -h
```

## Try it out

First set up a test app:
```bash
react-native init TestApp
cd TestApp
yarn add react-native-webview
react-native link react-native-webview
git init .
git add .
git commit -m'Before conversion'
```

Now do the conversion:
```bash
rn react_pod
git status
```
